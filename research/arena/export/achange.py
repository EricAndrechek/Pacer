"""SwiftData's persistent history (`ACHANGE` / `ATRANSACTION`), decoded.

An update's `ZCOLUMNS` is a bitmap over the entity's attributes in
alphabetical order, most significant bit first: byte 0's 0x80 is attribute
0. For TokenSample that puts accountId at bit 0, inferenceGeo at 7,
outputTokens at 12, projectPath at 13 and speed at 17 (spec §2.1). The
order is derived from the table's own columns, so a store with a new
attribute decodes correctly, and the bits the exporter depends on are
checked by name.

History keeps no old values: a change says *that* and *when*, never what a
column held before.
"""
from __future__ import annotations

INSERT, UPDATE, DELETE = 0, 1, 2

# Revision kinds (turn_revisions.kind) and the TokenSample attributes behind them.
KIND_BY_ATTR = {
    "ACCOUNTID": "account_restamp",
    "OUTPUTTOKENS": "output_upgrade",
    "PROJECTPATH": "project_rewrite",
    "INFERENCEGEO": "geo_speed_patch",
    "SPEED": "geo_speed_patch",
}
EXPECTED_TOKENSAMPLE_BITS = {"ACCOUNTID": 0, "INFERENCEGEO": 7, "OUTPUTTOKENS": 12,
                             "PROJECTPATH": 13, "SPEED": 17}


def attribute_order(table_columns: list[str]) -> list[str]:
    """Attribute names (without the Z prefix) in bitmap order: Core Data's
    own columns (Z_PK, Z_ENT, Z_OPT) dropped, the rest sorted by name.
    Upper-cased names sort the same as the model's camelCase ones as long as
    no two names differ only by case, which holds for every Pacer entity."""
    names = [c[1:] for c in table_columns if c.startswith("Z") and not c.startswith("Z_")]
    return sorted(names)


def decode_bits(blob: bytes | None) -> list[int]:
    """Indices of the set bits, MSB-first within each byte."""
    if not blob:
        return []
    out = []
    for i, byte in enumerate(blob):
        if byte:
            for j in range(8):
                if byte & (0x80 >> j):
                    out.append(i * 8 + j)
    return out


def changed_attributes(blob: bytes | None, order: list[str]) -> list[str]:
    return [order[i] for i in decode_bits(blob) if i < len(order)]


def check_tokensample_order(order: list[str]) -> None:
    for name, bit in EXPECTED_TOKENSAMPLE_BITS.items():
        if name not in order:
            raise ValueError(f"TokenSample has no attribute {name}")
        if order.index(name) != bit:
            raise ValueError(f"TokenSample attribute {name} is bit {order.index(name)}, expected {bit}")
