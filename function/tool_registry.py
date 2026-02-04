"""
Tool Registry - Loads tool definitions and maps tools to trifecta conditions.
"""

import json
import os

_registry = None


def _load_registry():
    global _registry
    if _registry is not None:
        return _registry

    tools_path = os.path.join(os.path.dirname(__file__), "tools.json")
    with open(tools_path, "r") as f:
        _registry = json.load(f)
    return _registry


def get_all_tools() -> list[dict]:
    """Return the full list of tool definitions."""
    registry = _load_registry()
    return registry["tools"]


def get_tool_conditions() -> dict[str, str]:
    """Return a mapping of tool_name -> condition."""
    registry = _load_registry()
    return {tool["name"]: tool["condition"] for tool in registry["tools"]}


def get_condition_for_tool(tool_name: str) -> str | None:
    """Return the trifecta condition for a given tool, or None if unknown."""
    return get_tool_conditions().get(tool_name)


def get_conditions_metadata() -> dict:
    """Return the conditions metadata (descriptions and tool lists)."""
    registry = _load_registry()
    return registry["conditions"]


def is_known_tool(tool_name: str) -> bool:
    """Check if a tool is in the registry."""
    return tool_name in get_tool_conditions()
