"""Strict request validation shared by the HTTP routes."""

import re

MAX_REQUEST_BYTES = 4096
MAX_SESSION_ID_LENGTH = 128
MAX_TOOL_NAME_LENGTH = 64

_SESSION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_TOOL_NAME = re.compile(r"^[a-z][a-z0-9_:-]{0,63}$")


class RequestValidationError(ValueError):
    pass


def validate_session_id(value) -> str:
    if not isinstance(value, str) or not _SESSION_ID.fullmatch(value):
        raise RequestValidationError(
            "session_id must be 1-128 characters using letters, digits, '.', '_', ':', or '-'"
        )
    return value


def validate_tool_name(value) -> str:
    if not isinstance(value, str) or not _TOOL_NAME.fullmatch(value):
        raise RequestValidationError(
            "tool_name must be 1-64 lowercase characters using letters, digits, '_', ':', or '-'"
        )
    return value


def validate_evaluation_payload(body) -> tuple[str, str]:
    if not isinstance(body, dict):
        raise RequestValidationError("JSON body must be an object")
    expected = {"session_id", "tool_name"}
    missing = sorted(expected - body.keys())
    extra = sorted(body.keys() - expected)
    if missing:
        raise RequestValidationError(f"Missing required fields: {missing}")
    if extra:
        raise RequestValidationError(f"Unexpected fields: {extra}")
    return validate_session_id(body["session_id"]), validate_tool_name(
        body["tool_name"]
    )
