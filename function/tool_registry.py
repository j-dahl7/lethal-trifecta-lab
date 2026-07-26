"""Validated, immutable-on-read tool registry."""

import copy
import json
import os
import re
import threading

_TOOL_NAME = re.compile(r"^[a-z][a-z0-9_:-]{0,63}$")
_ALLOWED_CONDITIONS = {
    "private_data",
    "untrusted_content",
    "exfiltration_vector",
}
_registry = None
_registry_lock = threading.Lock()


def _validate_registry(registry: dict) -> dict:
    if not isinstance(registry, dict):
        raise RuntimeError("Tool registry must be an object")
    tools = registry.get("tools")
    conditions = registry.get("conditions")
    if not isinstance(tools, list) or not isinstance(conditions, dict):
        raise RuntimeError("Tool registry schema is invalid")
    if set(conditions) != _ALLOWED_CONDITIONS:
        raise RuntimeError("Tool registry conditions are incomplete or unknown")

    names = set()
    mapped: dict[str, set[str]] = {condition: set() for condition in conditions}
    for tool in tools:
        if not isinstance(tool, dict):
            raise RuntimeError("Tool entries must be objects")
        name = tool.get("name")
        condition = tool.get("condition")
        if not isinstance(name, str) or not _TOOL_NAME.fullmatch(name):
            raise RuntimeError("Tool name is invalid")
        if name in names:
            raise RuntimeError(f"Duplicate tool name: {name}")
        if condition not in _ALLOWED_CONDITIONS:
            raise RuntimeError(f"Unknown condition for tool: {name}")
        names.add(name)
        mapped[condition].add(name)

    for condition, metadata in conditions.items():
        if not isinstance(metadata, dict) or set(metadata.get("tools", [])) != mapped[
            condition
        ]:
            raise RuntimeError(f"Condition metadata mismatch: {condition}")
    return registry


def _load_registry():
    global _registry
    if _registry is not None:
        return _registry
    with _registry_lock:
        if _registry is None:
            tools_path = os.path.join(os.path.dirname(__file__), "tools.json")
            with open(tools_path, "r", encoding="utf-8") as handle:
                _registry = _validate_registry(json.load(handle))
    return _registry


def get_all_tools() -> list[dict]:
    return copy.deepcopy(_load_registry()["tools"])


def get_tool_conditions() -> dict[str, str]:
    return {tool["name"]: tool["condition"] for tool in _load_registry()["tools"]}


def get_condition_for_tool(tool_name: str) -> str | None:
    return get_tool_conditions().get(tool_name)


def get_conditions_metadata() -> dict:
    return copy.deepcopy(_load_registry()["conditions"])


def is_known_tool(tool_name: str) -> bool:
    return tool_name in get_tool_conditions()
