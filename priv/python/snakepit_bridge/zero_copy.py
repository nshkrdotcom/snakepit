"""
Zero-copy handle helpers for Snakepit bridge.

This is a lightweight representation used to detect DLPack/Arrow handles.
"""

from typing import Any, Dict


class ZeroCopyRef:
    def __init__(self, payload: Dict[str, Any]):
        self.payload = payload
        self.kind = payload.get("kind")
        self.device = payload.get("device")
        self.dtype = payload.get("dtype")
        self.shape = payload.get("shape")
        self.owner = payload.get("owner")
        self.ref = payload.get("ref")
        self.copy = payload.get("copy")
        self.bytes = payload.get("bytes")
        self.metadata = payload.get("metadata", {})

    @classmethod
    def from_payload(cls, payload: Dict[str, Any]):
        return cls(payload)

    def to_payload(self) -> Dict[str, Any]:
        return dict(self.payload)

    def __repr__(self) -> str:
        return f"<ZeroCopyRef kind={self.kind} device={self.device} ref={self.ref}>"
