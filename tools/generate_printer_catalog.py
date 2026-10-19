#!/usr/bin/env python3
"""tools/generate_printer_catalog.py

Generate the printer recipe catalog for the StationeersLua printer-automation
plan (plan-388f267c1912da2a.md). Reads a Stationeers ``modconfig.xml``,
determines which mods are *enabled*, parses the vanilla recipe data plus every
enabled mod's recipe contributions, resolves overrides deterministically,
validates the result, and emits a Lua 5.1 catalog module (``PrinterCatalog.lua``).

The emitted file is a standalone *library chip*: it begins with a
``--@module PrinterCatalog`` annotation and returns a single module table, so a
consuming chip on the same data network loads it with ``require`` and can
hot-reload it with ``require("PrinterCatalog", true)`` -- it is never inlined
into another chip's source. Update = regenerate + redeploy THIS file only.

Design notes / why it does what it does:

* Enabled mods come from a Stationeers ModConfig document, which has two on-disk
  shapes this generator understands:
``    <Workshop Enabled="true|false">        (absolute-path form, e.g. the
  ``C:\\...\\Documents\\My Games\\Stationeers\\modconfig.xml`` the game writes)
      <Path Value="D:\\SteamLibrary\\steamapps\\workshop\\content\\544550\\3739533789" />
      <WorkshopId Value="3739533789" />
    </Workshop>
````    <Local Enabled="true">              (handle form, e.g. a repo copy)
      <Path Value="Workshop_3739533789" />
    </Local>
````
  ``Enabled`` is honoured: disabled mods contribute no recipes.
* Recipe data is ``<GameData>`` docs. A *container* element
  (``<AutolatheRecipes>``, ``<HydraulicPipeBenderRecipes>`` ...) selects the
  printer family, so the *file name is not trusted*: a mod may put, e.g., a
  ``<ToolManufactoryRecipes>`` container inside a file named ``electronics.xml``
  (ScriptedScreens does this), and one file may hold MORE THAN ONE container of
  the same family (Mon-O-Rail has two ``<ElectronicsPrinterRecipes>`` sections).
  Every ``<XxxRecipes>`` container in every parsed file is honoured.
* Costs may be fractional (``.5``, ``0.5``). Parsed with ``Decimal`` and emitted
  as fixed-point integers at ``SCALE = 1,000,000`` per reagent unit. Values not
  exactly representable at this scale, and negative/non-finite values, are
  rejected for that recipe and the recipe is kept visible with a ``reason``
  rather than silently rounded/dropped (per plan).
* Printer yield is NOT a furnace ``<Output>`` multiplier; Time/Energy are read
  as stored, never multiplied into a product count.
* Prefab hashes are runtime-computed by the controller, so the catalog keys
  recipes by stable prefab *name* and never guesses the hash algorithm.
* "Unknown reagent" fields are flagged (kept visible with a reason), not silently
  dropped, so a future mod typo surfaces instead of vanishing.
* Out-of-scope production families (furnaces, automated oven, packaging,
  recycling, reagent grinder, ...) are excluded automatically because their
  containers are not in ``CONTAINER_TO_FAMILY``.
* Determinism: families, prefabs, reagents and sources are emitted in a sorted /
  stable order, and the catalog revision is a SHA-256 over the canonical
  *effective content* + *effective source order* + reagent metadata, all
  path-independent, so ``--check`` is reproducible across machines. ``--check``
  regenerates in memory and compares bytes; it never rewrites the outputs.

Standard library only. No third-party dependencies, no new runtime mod.

Usage:
  python tools/generate_printer_catalog.py \
      --game-root "D:/SteamLibrary/steamapps/common/Stationeers" \
      --mod-config "C:/Users/AMPW/Documents/My Games/Stationeers/modconfig.xml" \
      [--profile "C:/Users/AMPW/Documents/My Games/Stationeers/profiles/modded.xml"] \
      [--out-dir DIR] [--check] [--allow-conflicts]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from decimal import Decimal, InvalidOperation, getcontext
from typing import Dict, List, Optional, Tuple

getcontext().prec = 40

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

# Fixed-point scale: a reagent cost of ``a`` is stored as int(a * SCALE).
SCALE = 1_000_000

API_VERSION = 1

# Container tag -> family id. The container, not the file name, selects the
# family, so cross-container files and multiple containers per file are handled.
CONTAINER_TO_FAMILY = {
    "AutolatheRecipes": "autolathe",
    "HydraulicPipeBenderRecipes": "pipebender",
    "ElectronicsPrinterRecipes": "electronics",
    "RocketManufactoryRecipes": "rocket",
    "ToolManufactoryRecipes": "tool",
    "SecurityPrinterRecipes": "security",
    "IngotRecipes": "ingots",
}

# The six productive printer families. "ingots" is a support/conversion family,
# catalogued for mass math but not a printable family.
PRINTER_FAMILIES = ["autolathe", "pipebender", "electronics", "rocket", "tool", "security"]
ALL_FAMILIES = PRINTER_FAMILIES + ["ingots"]

# The fixed library-chip module name the catalog emits and that consumers load
# with require("PrinterCatalog"). Kept as a single constant so the source
# annotation and the documented require target can never drift.
MODULE_NAME = "PrinterCatalog"

# <Recipe> children that are NOT reagent costs.
_NON_REAGENT_KEYS = {"Time", "Energy", "Output", "TimeScale"}

# Valid <RecipeTier> token -> integer tier.
_TIER_TOKENS = {"tierone": 1, "tiertwo": 2}

# Family numeric ids, stable across generations (emitted into the catalog).
_FAMILY_INDEX = {f: i + 1 for i, f in enumerate(ALL_FAMILIES)}

# Subdirectories that carry mod metadata / language, not recipe containers.
_SKIP_DIRS = {"language", "languages", "lang", "moddata", "moddata2", "about", "assets"}

# Rich-markup patterns stripped from display values.
_RICH_BRACE = re.compile(r"\{[^{}]*\}")     # {LINK:..;..} {GAS:..}
_RICH_ANGLE = re.compile(r"<[^>]*>")        # <b>..</b>
_WS = re.compile(r"\s+")


class CatalogError(Exception):
    """Fatal catalog-generation error (invalid input / unresolved conflict)."""


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def _as_bool(s, default=False) -> bool:
    if s is None:
        return default
    s = s.strip().lower()
    if s in ("true", "1", "yes", "on"):
        return True
    if s in ("false", "0", "no", "off", ""):
        return False
    return default


def _element_path_el(path_el) -> str:
    """Read a <Path Value=.../> (attribute preferred) or text child."""
    if path_el is None:
        return ""
    v = path_el.get("Value")
    if v:
        return v
    return (path_el.text or "").strip()


def _element_value(el) -> Optional[str]:
    if el is None:
        return None
    v = el.get("Value")
    if v:
        return v
    txt = (el.text or "").strip()
    return txt or None


def clean_markup(s: str) -> str:
    """Strip rich-text markup and collapse whitespace from a display value."""
    if not s:
        return ""
    s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    s = _RICH_BRACE.sub(" ", s)
    s = _RICH_ANGLE.sub(" ", s)
    return _WS.sub(" ", s).strip()


def dec_to_str(d) -> str:
    """Canonical, path-independent string form of a Decimal time/energy value."""
    return str(d.normalize())


def fixed_point(amount_int: int) -> str:
    """Inverse of fixed-point: integer count-at-SCALE -> decimal string."""
    return str(Decimal(amount_int) / Decimal(SCALE))


# ---------------------------------------------------------------------------
# Mod configuration parsing (both workshop/local shapes)
# ---------------------------------------------------------------------------

def parse_mod_config(path: str) -> List[Tuple[bool, str, str]]:
    """Return (enabled, workshop_id, stored_path) in document order.

    Handles ``<Workshop><Path Value/><WorkshopId Value/></Workshop>`` (absolute
    path + explicit id) and ``<Local><Path Value="Workshop_<id>"/>`` (bare
    handle). Document order is the recorded effective order.
    """
    root = ET.parse(path).getroot()
    out: List[Tuple[bool, str, str]] = []
    for w in root.findall("Workshop"):
        enabled = _as_bool(w.get("Enabled"), default=False)
        path = _element_path_el(w.find("Path"))
        wid = _element_value(w.find("WorkshopId"))
        if not wid and path:
            wid = os.path.basename(path.rstrip("/\\"))
        out.append((enabled, wid or "unknown", path))
    for l in root.findall("Local"):
        enabled = _as_bool(l.get("Enabled"), default=False)
        raw = _element_path_el(l.find("Path"))
        wid = raw[len("Workshop_"):] if raw.startswith("Workshop_") else raw
        out.append((enabled, wid, raw))
    return out


def resolve_mod_dir(label: str, stored: str, mod_base: Optional[str]) -> str:
    """Resolve a mod's on-disk directory.

    With ``--mod-base`` (hermetic tests) every mod resolves to
    ``mod_base/<id>`` regardless of the stored path. Otherwise the stored
    absolute path (Workshop shape) is used; a bare ``Workshop_<id>`` handle is
    resolved against ``workshop/content/<id>`` when a mod base is otherwise set.
    """
    if mod_base:
        return os.path.join(mod_base, label)
    if stored and os.path.isabs(stored):
        return stored
    if stored and stored.startswith("Workshop_"):
        return os.path.join("workshop", "content", label, label)
    return ""


# ---------------------------------------------------------------------------
# Recipe XML parsing
# ---------------------------------------------------------------------------

class Candidate:
    """One parsed recipe, prior to override resolution."""

    __slots__ = ("family", "prefab", "tier", "time", "energy", "reagents",
                 "reasons", "source", "file", "container", "index",
                 "fingerprint", "valid", "source_label")

    def __init__(self, family, prefab, tier, time, energy, reagents,
                 reason_list, source, relpath, container, index, source_label):
        self.family = family
        self.prefab = prefab
        self.tier = tier
        self.time = time            # Decimal | None
        self.energy = energy        # Decimal | None
        self.reagents = reagents    # dict key -> int fixed-point
        self.reasons = list(reason_list)
        self.source = source
        self.file = relpath
        self.container = container
        self.index = index
        self.source_label = source_label
        self.fingerprint = recipe_fingerprint(self)
        # Only structurally fatal issues make a recipe invalid; notes (unknown
        # reagent, non-representable cost, ...) stay visible without hiding it.
        self.valid = not any(r.startswith("fatal_") for r in self.reasons)


def recipe_fingerprint(c: Candidate) -> str:
    """Stable SHA-256 over canonical recipe content (order-independent)."""
    payload = {
        "family": c.family,
        "prefab": c.prefab,
        "tier": c.tier,
        "time": dec_to_str(c.time) if c.time is not None else None,
        "energy": dec_to_str(c.energy) if c.energy is not None else None,
        "reagents": {k: c.reagents[k] for k in sorted(c.reagents)},
    }
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def _scalar_decimal(text: Optional[str]) -> Optional[Decimal]:
    if text is None:
        return None
    s = text.strip()
    if s == "":
        return None
    try:
        d = Decimal(s)
    except InvalidOperation:
        return None
    if d.is_nan() or d.is_infinite():
        return None
    return d


def parse_recipe_data(node, family, source_label, relpath, container, index,
                      known: Optional[set]) -> Candidate:
    """Parse one <RecipeData> node into a Candidate.

    Structurally fatal issues prefix the reason with ``fatal_`` so ``valid``
    reflects only unusable recipes; notes are kept visible.
    """
    reasons: List[str] = []

    prefab_el = node.find("PrefabName")
    prefab = (prefab_el.text or "").strip() if prefab_el is not None else ""
    if not prefab:
        reasons.append("fatal_missing_prefab")
        prefab = "<unknown>"

    # <RecipeTier> sits at <RecipeData> level; fall back to <Recipe> if nested.
    tier_el = node.find("RecipeTier")
    recipe_el = node.find("Recipe")
    if tier_el is None and recipe_el is not None:
        tier_el = recipe_el.find("RecipeTier")
    tier = 1
    if tier_el is not None and (tier_el.text or "").strip():
        tok = tier_el.text.strip().lower()
        if tok in _TIER_TOKENS:
            tier = _TIER_TOKENS[tok]
        else:
            reasons.append("unknown_tier:%s" % tier_el.text.strip())

    time = _scalar_decimal(node.find("Time").text if node.find("Time") is not None else None)
    energy = _scalar_decimal(node.find("Energy").text if node.find("Energy") is not None else None)

    reagents: Dict[str, int] = {}
    reagent_child_count = 0
    unresolved = False
    if recipe_el is None:
        reasons.append("fatal_missing_recipe_block")
    else:
        for r in recipe_el:
            if r.tag in _NON_REAGENT_KEYS or r.tag == "RecipeTier":
                continue
            reagent_child_count += 1
            raw = (r.text or "").strip()
            d = _scalar_decimal(raw or None)
            if d is None:
                reasons.append("invalid_or_nonfinite_reagent:%s=%r" % (r.tag, raw))
                unresolved = True
                continue
            if d < 0:
                reasons.append("negative_reagent:%s=%s" % (r.tag, raw))
                unresolved = True
                continue
            fixed = int(d * SCALE)
            if Decimal(fixed) != d * SCALE:
                reasons.append("nonrepresentable_reagent:%s=%s" % (r.tag, raw))
                unresolved = True
                continue
            reagents[r.tag] = max(reagents.get(r.tag, 0), fixed)
            if known is not None and r.tag not in known and d != 0:
                reasons.append("unknown_reagent:%s" % r.tag)

    # Carried reagent children but resolved none: suspicious but not fatal.
    if reagent_child_count and not reagents:
        reasons.append("some_reagents_unresolved" if unresolved else "no_reagents_resolved")

    return Candidate(family, prefab, tier, time, energy, reagents, reasons,
                     source_label, relpath, container, index, source_label)


def iter_recipe_candidates(path: str, source_label: str,
                           known: Optional[set]):
    """Yield Candidate for every <XxxRecipes>/<RecipeData> container in a file.

    Ignores XML comments (ElementTree drops them) and unknown containers.
    """
    tree = ET.parse(path)
    root = tree.getroot()
    idx = 0
    for container in root:
        if container.tag not in CONTAINER_TO_FAMILY:
            continue
        family = CONTAINER_TO_FAMILY[container.tag]
        for rd in container.findall("RecipeData"):
            yield parse_recipe_data(rd, family, source_label,
                                    os.path.basename(path), container.tag,
                                    idx, known)
            idx += 1


# ---------------------------------------------------------------------------
# Language registry (reagent + thing display names)
# ---------------------------------------------------------------------------

def _is_english(fname: str, root) -> bool:
    fl = fname.lower()
    if "english" in fl or fl.endswith("_en.xml") or fl == "en.xml":
        return True
    if root is not None:
        code = root.find("Code")
        if code is not None and (code.text or "").strip().upper() == "EN":
            return True
    return False


class LanguageRegistry:
    """Merged reagent + thing display metadata.

    English entries win over other languages; later sources override earlier
    ones. Values are rich-markup-stripped.
    """

    def __init__(self):
        self.things: Dict[str, str] = {}       # prefab key -> display
        self.reagents: Dict[str, dict] = {}     # reagent key -> {name, unit}

    def add_file(self, path: str):
        try:
            tree = ET.parse(path)
        except ET.ParseError:
            return
        root = tree.getroot()
        english = _is_english(os.path.basename(path), root)

        reagents_el = root.find("Reagents")
        if reagents_el is not None:
            for rr in reagents_el.findall("RecordReagent"):
                key_el = rr.find("Key")
                if key_el is None:
                    continue
                key = (key_el.text or "").strip()
                if not key:
                    continue
                val_el = rr.find("Value")
                value = clean_markup(val_el.text) if val_el is not None and val_el.text else ""
                unit_el = rr.find("Unit")
                unit = (unit_el.text or "").strip() if unit_el is not None else ""
                if english or key not in self.reagents:
                    self.reagents[key] = {"name": value or key, "unit": unit}

        things_el = root.find("Things")
        if things_el is not None:
            for rt in things_el.findall("RecordThing"):
                key_el = rt.find("Key")
                if key_el is None:
                    continue
                key = (key_el.text or "").strip()
                if not key:
                    continue
                val_el = rt.find("Value")
                disp = clean_markup(val_el.text) if val_el is not None and val_el.text else ""
                if english or key not in self.things:
                    self.things[key] = disp or key

    def display(self, prefab: str) -> str:
        return self.things.get(prefab) or prefab


def _walk_recipe_xmls(base_dir: str):
    """Yield .xml paths under base_dir, skipping non-recipe / language dirs."""
    for root, dirs, files in os.walk(base_dir):
        bl = os.path.basename(root).lower()
        if bl in _SKIP_DIRS:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d.lower() not in _SKIP_DIRS]
        for f in sorted(files):
            if f.lower().endswith(".xml"):
                yield os.path.join(root, f)


def _find_language_files(dir_path: str) -> List[str]:
    """List .xml files directly in dir_path (no subdirs, no skip rules)."""
    if not dir_path or not os.path.isdir(dir_path):
        return []
    return [os.path.join(dir_path, f) for f in sorted(os.listdir(dir_path))
            if f.lower().endswith(".xml")]


def load_language(game_root: str, mod_dirs: List[Tuple[str, str]]) -> LanguageRegistry:
    reg = LanguageRegistry()

    for candidate_lang in (
        os.path.join(game_root, "rocketstation_Data", "StreamingAssets", "Language"),
        os.path.join(game_root, "Content", "Language"),
    ):
        if os.path.isdir(candidate_lang):
            # vanilla language lowest priority: non-English first, English wins.
            files = _find_language_files(candidate_lang)
            for f in [f for f in files if not _is_english(os.path.basename(f), _rootcode(f))]:
                reg.add_file(f)
            for f in [f for f in files if _is_english(os.path.basename(f), _rootcode(f))]:
                reg.add_file(f)
            break

    for _label, mdir in mod_dirs:
        for lang_dir in _find_language_dirs(mdir):
            files = _find_language_files(lang_dir)
            for f in [f for f in files if not _is_english(os.path.basename(f), _rootcode(f))]:
                reg.add_file(f)
            for f in [f for f in files if _is_english(os.path.basename(f), _rootcode(f))]:
                reg.add_file(f)
    return reg


def _find_language_dirs(mdir: str) -> List[str]:
    out = []
    for root, dirs, _ in os.walk(mdir):
        bl = os.path.basename(root).lower()
        if bl in ("language", "languages", "lang"):
            out.append(root)
            dirs[:] = []
        else:
            dirs[:] = [d for d in dirs if d.lower() not in _SKIP_DIRS]
    if not out:
        gd = os.path.join(mdir, "GameData", "Language")
        if os.path.isdir(gd):
            out.append(gd)
    return out


def _rootcode(path):
    try:
        return ET.parse(path).getroot()
    except ET.ParseError:
        return None


def collect_candidates(base_dir: str, label: str, known: Optional[set]) -> List[Candidate]:
    """All candidates from a source dir, in deterministic file order."""
    out: List[Candidate] = []
    if not base_dir or not os.path.isdir(base_dir):
        return out
    for path in _walk_recipe_xmls(base_dir):
        try:
            for cand in iter_recipe_candidates(path, label, known):
                out.append(cand)
        except ET.ParseError as e:
            raise CatalogError("malformed XML in %s: %s" % (path, e))
    out.sort(key=lambda c: (c.file, c.index))
    return out


def resolve_vanilla_data(game_root: str) -> str:
    for c in (os.path.join(game_root, "rocketstation_Data", "StreamingAssets", "Data"),
              os.path.join(game_root, "Content", "Data"),
              game_root):
        if os.path.isdir(c):
            return c
    raise CatalogError("could not locate vanilla Data under %r" % game_root)


# ---------------------------------------------------------------------------
# Catalog assembly + override resolution
# ---------------------------------------------------------------------------

class Catalog:
    def __init__(self):
        self.families: Dict[str, Dict[str, Candidate]] = {f: {} for f in ALL_FAMILIES}
        self.sources_for: Dict[str, Dict[str, List[str]]] = {f: {} for f in ALL_FAMILIES}
        self.effective_order: List[str] = []
        self.conflicts: List[dict] = []     # differing-fingerprint overrides
        self.benign: List[dict] = []        # identical redeclarations
        self.ingots: Dict[str, dict] = {}    # reagent -> {item, amount, ...}
        self.output_ambiguous: List[dict] = []
        self.language: Optional[LanguageRegistry] = None
        self.known_reagents: Optional[set] = None
        self.sources_meta: List[dict] = []
        self.revision = ""

    def apply_source_in_order(self, source_label: str, candidates: List[Candidate]):
        for cand in candidates:
            cand.source_label = source_label
            cand.source = cand.file
            self._apply_one(cand)

    def _apply_one(self, cand: Candidate):
        family = cand.family
        key = cand.prefab
        self.sources_for[family].setdefault(key, [])
        prev = self.families[family].get(key)
        if prev is not None:
            if prev.fingerprint != cand.fingerprint:
                self.conflicts.append({
                    "family": family, "prefab": key,
                    "old_fp": prev.fingerprint, "new_fp": cand.fingerprint,
                    "old_source": prev.source_label, "new_source": cand.source_label,
                    "old_tier": prev.tier, "new_tier": cand.tier,
                })
                self.sources_for[family][key] = [cand.source_label]
            else:
                self.benign.append({"family": family, "prefab": key,
                                    "sources": [prev.source_label, cand.source_label]})
                if cand.source_label not in self.sources_for[family][key]:
                    self.sources_for[family][key].append(cand.source_label)
        else:
            self.sources_for[family][key].append(cand.source_label)
        self.families[family][key] = cand          # last-wins
        if cand.source_label not in self.effective_order:
            self.effective_order.append(cand.source_label)

    def build_ingots(self):
        """Map reagent -> ingot prefab from the ingots family; detect ambiguity."""
        for cand in self.families["ingots"].values():
            if not cand.valid:
                continue
            ingot = cand.prefab
            for reagent, amount in cand.reagents.items():
                entry = self.ingots.get(reagent)
                if entry is None:
                    self.ingots[reagent] = {
                        "item": ingot, "amount": fixed_point(amount),
                        "amount_fixed": amount, "source": cand.source_label,
                    }
                elif entry["item"] != ingot or entry["amount_fixed"] != amount:
                    self.conflicts.append({
                        "family": "ingots", "prefab": "conversion:%s" % reagent,
                        "old_fp": entry["item"], "new_fp": ingot,
                        "old_source": entry["source"], "new_source": cand.source_label,
                        "old_tier": 1, "new_tier": 1,
                    })
                    self.output_ambiguous.append({
                        "family": "ingots", "prefab": reagent,
                        "detail": "%s vs %s" % (entry["item"], ingot),
                    })
        ingot_names = {e["item"] for e in self.ingots.values()}
        for family in PRINTER_FAMILIES:
            for cand in self.families[family].values():
                if cand.valid and cand.prefab in ingot_names:
                    self.output_ambiguous.append({
                        "family": family, "prefab": cand.prefab,
                        "detail": "printer product is also an ingot output",
                    })

    def revision_of(self) -> str:
        """Path-independent SHA-256 over canonical effective content."""
        payload = {
            "api_version": API_VERSION,
            "effective_order": self.effective_order,
            "families": {},
            "ingots": {},
            "reagents": ({k: v for k, v in sorted(self.language.reagents.items())}
                         if self.language else {}),
            "things_count": len(self.language.things) if self.language else 0,
        }
        for family in ALL_FAMILIES:
            fam = {}
            for prefab in sorted(self.families[family]):
                c = self.families[family][prefab]
                fam[prefab] = {
                    "family": family,
                    "min_tier": c.tier,
                    "time": dec_to_str(c.time) if c.time is not None else None,
                    "energy": dec_to_str(c.energy) if c.energy is not None else None,
                    "reagents": {k: c.reagents[k] for k in sorted(c.reagents)},
                    "valid": c.valid,
                    "reasons": list(c.reasons),
                    "fingerprint": c.fingerprint,
                    "sources": list(self.sources_for[family].get(prefab, [])),
                }
            payload["families"][family] = fam
        for reagent in sorted(self.ingots):
            e = self.ingots[reagent]
            payload["ingots"][reagent] = {"item": e["item"], "amount": e["amount"]}
        blob = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def gather_known_reagents(catalog: Catalog) -> set:
    """Authoritative reagent set = language RecordReagent keys + ingot inputs.

    A reagent is "known" if the game lists it as a reagent (language) or an
    ingot conversion consumes it. Unknown-but-well-formed recipe reagent
    children are flagged without being treated as fatal.
    """
    known = set()
    if catalog.language:
        known.update(catalog.language.reagents.keys())
    for cand in catalog.families.get("ingots", {}).values():
        if cand.valid:
            for k in cand.reagents:
                known.add(k)
    return known


# ---------------------------------------------------------------------------
# Build orchestration
# ---------------------------------------------------------------------------

def build_catalog(game_root: str, mod_config_path: str,
                  profile_path: Optional[str] = None,
                  mod_base: Optional[str] = None,
                  allow_conflicts: bool = False):
    """Build and validate the effective catalog from vanilla + enabled mods."""
    entries = parse_mod_config(mod_config_path)

    mod_dirs: List[Tuple[str, str]] = []
    missing: List[Tuple[str, str, str]] = []
    for enabled, wid, stored in entries:
        if not enabled:
            continue
        mdir = resolve_mod_dir(wid, stored, mod_base)
        mod_dirs.append((wid, mdir))
        if not mdir or not os.path.isdir(mdir):
            missing.append((wid, mdir, stored))

    vanilla_data = resolve_vanilla_data(game_root)
    catalog = Catalog()

    # Language first, so the reagent set is known before flagging unknowns.
    catalog.language = load_language(game_root, mod_dirs)
    known = gather_known_reagents(catalog)

    catalog.sources_meta.append({"type": "vanilla", "path": vanilla_data})
    vanilla_cands = collect_candidates(vanilla_data, "vanilla", known)
    catalog.apply_source_in_order("vanilla", vanilla_cands)

    for wid, mdir in mod_dirs:
        if not os.path.isdir(mdir):
            catalog.conflicts.append({
                "family": "_", "prefab": "MISSING_MODDIR",
                "old_source": wid, "new_source": mdir,
            })
            continue
        mod_cands = collect_candidates(mdir, wid, known)
        catalog.apply_source_in_order(wid, mod_cands)

    catalog.known_reagents = gather_known_reagents(catalog)
    catalog.build_ingots()

    real_conflicts = [c for c in catalog.conflicts if c.get("family") != "_"]
    if missing:
        catalog.conflicts.append({
            "family": "_", "prefab": "MISSING_MODS",
            "old_source": "; ".join("%s->%s" % (w, p) for w, p, _ in missing),
            "new_source": "",
        })
    if real_conflicts and not allow_conflicts:
        _report_conflicts(catalog, fp_real_only=True)
        raise CatalogError("%d conflicting override(s); use --allow-conflicts to "
                           "continue (last-wins)" % len(real_conflicts))

    catalog.revision = catalog.revision_of()
    return catalog, entries, mod_dirs, missing


def _report_conflicts(catalog: Catalog, fp_real_only=True):
    sys.stderr.write("=== CONFLICTING OVERRIDES ===\n")
    for c in catalog.conflicts:
        if c.get("family") == "_":
            if fp_real_only:
                continue
            sys.stderr.write("  [info] %s: %s\n" %
                             (c.get("prefab"), c.get("new_source") or c.get("old_source")))
        else:
            sys.stderr.write("  %s / %s: %s(@%s,t%s) vs %s(@%s,t%s)\n" %
                             (c["family"], c["prefab"],
                              c["old_fp"], c["old_source"], c.get("old_tier", 1),
                              c["new_fp"], c["new_source"], c.get("new_tier", 1)))


# ---------------------------------------------------------------------------
# Lua emission
# ---------------------------------------------------------------------------

def lua_str(s: str) -> str:
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif 32 <= o < 127:
            out.append(ch)
        else:
            out.append("\\%03d" % o)
    out.append('"')
    return "".join(out)


def lua_num(v) -> str:
    if v is None:
        return "nil"
    if v == int(v):
        return str(int(v))
    return str(v)


def lua_key(s: str) -> str:
    """Emit a table key that is valid in Lua 5.1 *and* 5.3+.

    Lua 5.1 only accepts identifier or ``[expr]`` keys in table constructors;
    the bare ``"foo" = ...`` form is 5.3+ syntax. Quoting as ``["foo"]`` is
    portable to every Lua version the game could embed, and reads identically
    to a string key at runtime.
    """
    return "[%s]" % lua_str(s)


def emit_catalog(catalog: Catalog) -> str:
    lang = catalog.language
    L = []
    L.append("--@module %s" % MODULE_NAME)
    L.append("--@version %d" % API_VERSION)
    L.append("--@revision %s" % catalog.revision)
    L.append("-- Generated by tools/generate_printer_catalog.py -- DO NOT EDIT.")
    L.append("-- Library chip: a passive, dependency-free, UI-free, pin-free Lua module.")
    L.append("-- It has no VM of its own; it only PROVISIONS recipe data -- families /")
    L.append("-- recipes / ingots / reagents -- plus `api_version` + a content `revision`.")
    L.append("--")
    L.append("-- A consuming console UI chip on the SAME data network loads it with")
    L.append('-- require("%s") and hot-reloads a redeploy with' % MODULE_NAME)
    L.append('-- require("%s", true) WITHOUT restarting the chip that owns the UI; the' % MODULE_NAME)
    L.append("-- printer CONTROLLER does not consume this catalog. Update = regenerate +")
    L.append("-- redeploy THIS file only; chips re-require it on chip reload.")
    L.append("--")
    L.append("-- Keys recipes by prefab name (the controller computes prefab_hash at")
    L.append("-- runtime, so the catalog never guesses the hash algorithm).")
    L.append("-- Reagent/ingot amounts are the in-game gram equivalents (the internal")
    L.append("-- fixed-point scale of %d is applied only during parsing and DROPPED on" % SCALE)
    L.append("-- emission, so 2 g of a reagent reads as 2, not 2,000,000). The per-reagent")
    L.append("-- `unit` in `reagents` names the in-game unit. `api_version` + `revision` are")
    L.append("-- the version gate a consumer uses to detect a stale copy.")
    L.append("-- effective source order: " + ", ".join(catalog.effective_order))
    L.append("")
    L.append("local Catalog = {")
    L.append("  api_version = %d," % API_VERSION)
    L.append('  revision = "%s",' % catalog.revision)
    L.append("")
    L.append("  generated = {")
    L.append("    effective_order = { " + ", ".join(lua_str(x) for x in catalog.effective_order) + " },")
    L.append("  },")
    L.append("")
    L.append("  families = {")
    for family in ALL_FAMILIES:
        L.append("    %s = {" % lua_key(family))
        fam_map = catalog.families[family]
        for prefab in sorted(fam_map, key=str):
            c = fam_map[prefab]
            L.append("      %s = {" % lua_key(prefab))
            L.append("        family = %d," % _FAMILY_INDEX[family])
            L.append("        min_tier = %d," % c.tier)
            L.append("        time = %s," % lua_num(c.time))
            L.append("        energy = %s," % lua_num(c.energy))
            L.append("        valid = %s," % ("true" if c.valid else "false"))
            if c.reagents:
                entries = ", ".join(
                    "%s = %s" % (lua_key(r), fixed_point(c.reagents[r]))
                    for r in sorted(c.reagents, key=str))
                L.append("        reagents = { %s }," % entries)
            else:
                L.append("        reagents = {},")
            if c.reasons:
                L.append("        reasons = { " +
                         ", ".join(lua_str(r) for r in c.reasons) + " },")
            L.append('        fingerprint = "%s",' % c.fingerprint)
            srcs = sorted({s for s in catalog.sources_for[family].get(prefab, [])})
            L.append("        sources = { " + ", ".join(lua_str(s) for s in srcs) + " },")
            disp = lang.display(prefab) if lang else prefab
            L.append("        display = %s," % lua_str(disp))
            L.append("      },")
        L.append("    },")
    L.append("  },")
    L.append("")
    ingot_body = ", ".join(
        "%s = { item = %s, amount = %s }"
        % (lua_key(r), lua_str(e["item"]), fixed_point(e["amount_fixed"]))
        for r, e in sorted(catalog.ingots.items()))
    L.append("  ingots = { %s }," % ingot_body)
    L.append("")
    reagent_body = ", ".join(
        "%s = { name = %s, unit = %s }"
        % (lua_key(r), lua_str(e["name"]), lua_str(e["unit"]))
        for r, e in sorted((lang.reagents.items() if lang else [])))
    L.append("  reagents = { %s }," % reagent_body)
    L.append("")
    L.append("}")
    L.append("return Catalog")
    L.append("")
    return "\n".join(L)


# ---------------------------------------------------------------------------
# Standalone test emission (printer_recipe_test.lua)
# ---------------------------------------------------------------------------

def _catalog_literal_only(catalog_lua: str) -> str:
    """Return only the `local Catalog = { ... }` table literal (no header/return)."""
    lines = catalog_lua.split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.startswith("local Catalog = {"):
            start = i
            break
    if start is None:
        raise CatalogError("emitted catalog missing 'local Catalog = {' literal")
    depth = 0
    end = None
    for j in range(start, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth == 0 and j > start:
            end = j
            break
    if end is None or end <= start:
        raise CatalogError("emitted catalog literal not terminated")
    return "\n".join(lines[start:end + 1])


# A self-contained Lua 5.1 test. The catalog table literal is embedded so the
# test runs from anywhere with a bare lua5.1 -- it never loads the controller
# (the controller no longer consumes the catalog), so there is nothing to stub.
_TEST_TEMPLATE = u"""\
-- Generated by tools/generate_printer_catalog.py -- DO NOT EDIT.
-- printer_recipe_test.lua -- Lua 5.1 compatibility.
-- catalog library chip: {catalog}
-- revision: {revision}
-- families: {nfam}, recipes: {nrec}, invalid: {ninvalid}, ingots: {ning}, reagents: {nrea}

{literal}

local catalog = Catalog

local _fails = 0
local function check(cond, msg)
  if cond then
    print("  PASS " .. msg)
  else
    print("  FAIL " .. msg)
    _fails = _fails + 1
  end
end
local function eq(a, b, msg)
  check(a == b,
        msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

-- 0. structural
check(type(catalog) == "table", "Catalog was not returned")
check(type(catalog.api_version) == "number", "Catalog carries an api_version")
check(type(catalog.revision) == "string", "Catalog carries a revision")

-- 1. families / recipes
local fam_count = 0
local rec_count = 0
local n_invalid = 0
for _, fam in pairs(catalog.families or {}) do
  fam_count = fam_count + 1
  for _, rr in pairs(fam) do
    rec_count = rec_count + 1
    if rr.valid == false then
      n_invalid = n_invalid + 1
      print("  info invalid recipe: " .. tostring(rr.display))
    end
  end
end
eq(fam_count, {nfam}, "family count")
eq(rec_count, {nrec}, "recipe count")
eq(n_invalid, {ninvalid}, "invalid recipe count")

-- 2. ingots / reagents
local n_ing = 0
for _ in pairs(catalog.ingots or {}) do n_ing = n_ing + 1 end
eq(n_ing, {ning}, "ingot count")
local n_rea = 0
for _ in pairs(catalog.reagents or {}) do n_rea = n_rea + 1 end
eq(n_rea, {nrea}, "reagent count")

print("")
print(string.format("== printer recipe test: %d recipes, %d invalid",
                    rec_count, n_invalid))
if _fails == 0 then
  print(string.format("ALL CHECKS PASSED (%d families, %d recipes)",
                      fam_count, rec_count))
  return 0
end
print("FAILURES: " .. _fails)
return _fails
"""


def emit_test_script(catalog: Catalog,
                     catalog_module: str = "PrinterCatalog") -> str:
    """Produce a standalone, Lua-5.1-compatible printer_recipe_test.lua.

    The catalog table literal is embedded so the file runs from any working
    directory under a bare lua5.1. The controller is NOT referenced: option-1
    moved recipe consumption entirely to the consuming console chip, so the
    catalog is self-sufficient for structural validation.
    """
    literal = _catalog_literal_only(emit_catalog(catalog))
    n_fam = len(ALL_FAMILIES)
    n_rec = sum(len(catalog.families[f]) for f in ALL_FAMILIES)
    n_invalid = sum(1 for fam in catalog.families.values()
                    for r in fam.values() if not r.valid)
    n_ing = len(catalog.ingots)
    n_rea = len(catalog.language.reagents) if catalog.language else 0
    out = _TEST_TEMPLATE
    out = out.replace("{literal}", literal)
    out = out.replace("{catalog}", catalog_module)
    out = out.replace("{revision}", catalog.revision or "n/a")
    out = out.replace("{nfam}", str(n_fam))
    out = out.replace("{nrec}", str(n_rec))
    out = out.replace("{ninvalid}", str(n_invalid))
    out = out.replace("{ning}", str(n_ing))
    out = out.replace("{nrea}", str(n_rea))
    return out



# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _check_or_write(content: str, path: str, write: bool, label: str) -> int:
    if not os.path.isfile(path):
        if write:
            raise CatalogError("%s missing; run without --check first" % label)
        sys.stderr.write("[!%s] %s does not exist yet\n" % (label, label))
        return 1
    with open(path, "r", encoding="utf-8") as fh:
        existing = fh.read()
    if existing == content:
        if write:
            sys.stderr.write("[ok] %s up to date\n" % label)
        return 0
    sys.stderr.write("[x] %s DRIFTED from a fresh build\n" % label)
    import difflib
    diff = list(difflib.unified_diff(existing.split("\n"), content.split("\n"),
                                     fromfile=label + " (on-disk)",
                                     tofile=label + " (fresh)"))
    for i, line in enumerate(diff):
        sys.stderr.write(line + "\n")
        if i > 40:
            sys.stderr.write("... (%d more diff lines)\n" % (len(diff) - 41))
            break
    return 1


def _short_path(path, base):
    """Drive-agnostic relative path for the summary.

    ``os.path.relpath`` raises ValueError across drive roots on Windows (e.g.
    an output dir on `C:` while the tool's cwd is on `D:`). Fall back to the
    absolute path so the build can always finish.
    """
    try:
        return os.path.relpath(path, base)
    except ValueError:
        return os.path.abspath(path)


def _summary(catalog, entries, mod_dirs, missing, wrote, check=False):
    n_en = sum(1 for en, _w, _p in entries if en)
    n_off = len(entries) - n_en
    sys.stderr.write("=== printer catalog build ===\n")
    sys.stderr.write("mod-config entries: %d enabled, %d disabled; effective sources: %d\n"
                     % (n_en, n_off, len(catalog.effective_order)))
    sys.stderr.write("effective order: %s\n" % " -> ".join(catalog.effective_order))
    for fam in ALL_FAMILIES:
        total = len(catalog.families[fam])
        valid = sum(1 for c in catalog.families[fam].values() if c.valid)
        note = "  (all valid)" if valid == total else "  (%d flagged)" % (total - valid)
        sys.stderr.write("  %-14s %3d recipe(s)%s\n" % (fam, total, note))
    if missing:
        sys.stderr.write("missing mod dirs: %s\n" %
                         "; ".join("%s->%s" % (w, p) for w, p, _ in missing))
    real = [c for c in catalog.conflicts if c.get("family") != "_"]
    info = [c for c in catalog.conflicts if c.get("family") == "_"]
    sys.stderr.write("conflicts: %d real, %d info, benign redeclarations: %d\n" %
                     (len(real), len(info), len(catalog.benign)))
    for a in catalog.output_ambiguous:
        sys.stderr.write("  [ambig] %s / %s: %s\n" %
                         (a.get("family"), a.get("prefab"), a.get("detail")))
    sys.stderr.write("catalog revision: %s\n" % catalog.revision)
    for p in wrote:
        if p:
            sys.stderr.write("  %s %s\n" %
                             ("kept" if check else "wrote",
                              _short_path(p, os.getcwd())))


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="Generate the Stationeers printer recipe catalog "
                    "from vanilla + enabled mods.")
    p.add_argument("--game-root", required=True,
                   help="Stationeers install root (contains rocketstation_Data/...).")
    p.add_argument("--mod-config", required=True,
                   help="modconfig.xml listing enabled/disabled mods.")
    p.add_argument("--profile",
                   help="Optional active profile (modded.xml) for reference only.")
    p.add_argument("--mod-base",
                   help="Override workshop base dir (each mod -> <base>/<id>); "
                        "for hermetic tests using a repo copy of modconfig.")
    p.add_argument("--out-dir",
                   help="Output dir (default: repo root next to tools/).")
    p.add_argument("--check", action="store_true",
                   help="Regenerate and compare; do not write; exit nonzero on drift.")
    p.add_argument("--allow-conflicts", action="store_true",
                   help="Emit even when overrides conflict (last-wins).")
    p.add_argument("--quiet", action="store_true",
                   help="Suppress the human summary.")
    p.add_argument("--test-out", default=None,
                   help="Emit a standalone, Lua-5.1-compatible "
                        "printer_recipe_test.lua to this path (off by default). "
                        "In --check mode it is compared, not written.")
    args = p.parse_args(argv)

    out_dir = args.out_dir or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    catalog_lua_path = os.path.join(out_dir, "PrinterCatalog.lua")

    catalog, entries, mod_dirs, missing = build_catalog(
        args.game_root, args.mod_config, args.profile,
        mod_base=args.mod_base, allow_conflicts=args.allow_conflicts)

    catalog_lua = emit_catalog(catalog)

    wrote: List[str] = []
    if args.check:
        rc = _check_or_write(catalog_lua, catalog_lua_path, write=False,
                             label="PrinterCatalog.lua")
        if args.test_out:
            test_lua = emit_test_script(catalog)
            rc |= _check_or_write(test_lua, args.test_out, write=False,
                                  label="printer_recipe_test.lua")
        wrote_check = ([catalog_lua_path] +
                      ([args.test_out] if args.test_out else []))
        if not args.quiet:
            _summary(catalog, entries, mod_dirs, missing, wrote=wrote_check, check=True)
        return 1 if rc else 0

    with open(catalog_lua_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(catalog_lua)
    wrote.append(catalog_lua_path)

    if args.test_out:
        test_lua = emit_test_script(catalog)
        with open(args.test_out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(test_lua)
        wrote.append(args.test_out)

    if not args.quiet:
        _summary(catalog, entries, mod_dirs, missing, wrote=wrote, check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
