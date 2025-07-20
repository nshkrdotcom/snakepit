# MessagePack Wire Protocol Implementation Plan

## Executive Summary

This document outlines the complete implementation plan for replacing JSON with MessagePack as the wire protocol between Elixir and Python processes in Snakepit. This change is expected to deliver a 10x performance improvement, reducing serialization overhead from 200-500ms to 20-50ms per call.

## Current Architecture

### Wire Protocol Structure
```
[4-byte length header (big-endian)] [JSON payload]
```

### Current Flow
1. Elixir: Encode data with Jason → Write length header → Write JSON bytes
2. Python: Read length header → Read JSON bytes → Decode with json module
3. Both directions use the same protocol

## Proposed Architecture

### Wire Protocol Structure (unchanged)
```
[4-byte length header (big-endian)] [MessagePack payload]
```

### New Flow
1. Elixir: Encode data with Msgpax → Write length header → Write MessagePack bytes
2. Python: Read length header → Read MessagePack bytes → Decode with msgpack module
3. Both directions use the same protocol

## Implementation Plan

### Phase 1: Add Dependencies

#### Elixir Side
- Msgpax library already vendored at `/snakepit/msgpax/`
- Need to add to mix.exs dependencies

#### Python Side
- Add `msgpack` to requirements.txt
- Version: `msgpack>=1.0.5` (latest stable)

### Phase 2: Core Protocol Changes

#### 1. Protocol Module Updates

**File: `lib/snakepit/wire_protocol.ex`**
- Add MessagePack encoder/decoder functions
- Keep JSON functions for compatibility
- Add protocol version negotiation

**File: `python/snakepit/wire_protocol.py`**
- Add MessagePack encoder/decoder functions
- Keep JSON functions for compatibility
- Match Elixir-side protocol negotiation

#### 2. Process Communication Updates

**Elixir Side (`lib/snakepit/process.ex`)**
- Update `send_request/2` to use MessagePack
- Update `receive_response/1` to use MessagePack
- Add fallback to JSON for compatibility

**Python Side (`python/snakepit/process.py`)**
- Update request reading to use MessagePack
- Update response writing to use MessagePack
- Add fallback to JSON for compatibility

### Phase 3: Compatibility Strategy

#### Protocol Version Negotiation
1. On process startup, Python sends capabilities message
2. Elixir responds with selected protocol version
3. Both sides use negotiated protocol

#### Gradual Migration
1. Add `protocol_version` config option (default: "msgpack")
2. Support both JSON and MessagePack simultaneously
3. Allow per-process protocol selection

### Phase 4: Type Mapping

#### Elixir → Python
| Elixir Type | MessagePack | Python Type |
|-------------|-------------|-------------|
| nil | nil | None |
| true/false | boolean | True/False |
| integer | integer | int |
| float | float | float |
| atom | string | str |
| binary | binary | bytes |
| string | string | str |
| list | array | list |
| tuple | array | list |
| map | map | dict |
| keyword list | map | dict |

#### Python → Elixir
| Python Type | MessagePack | Elixir Type |
|-------------|-------------|-------------|
| None | nil | nil |
| True/False | boolean | true/false |
| int | integer | integer |
| float | float | float |
| str | string | string |
| bytes | binary | binary |
| list | array | list |
| tuple | array | list |
| dict | map | map |

### Phase 5: Error Handling

1. Protocol mismatch detection
2. Graceful fallback to JSON
3. Clear error messages for debugging
4. Logging of protocol negotiations

### Phase 6: Testing Strategy

1. Unit tests for encoders/decoders
2. Integration tests for end-to-end communication
3. Compatibility tests (JSON ↔ MessagePack)
4. Performance benchmarks
5. Load testing with large payloads

### Phase 7: Performance Optimizations

1. Use iodata in Elixir for zero-copy sends
2. Streaming support for large messages
3. Connection pooling remains unchanged
4. Binary data handling without base64 encoding

## Benefits

### Performance
- 10x reduction in serialization overhead
- Native binary support (no base64 encoding)
- Smaller message sizes (2-10x compression)
- Faster parsing due to binary format

### Capabilities
- Direct binary data transfer
- Better number type preservation
- Enables real-time applications
- Supports video/image processing

### Compatibility
- Backward compatible with JSON
- Gradual migration path
- No breaking changes to API

## Risks and Mitigations

### Risk 1: Breaking Existing Deployments
**Mitigation**: Protocol version negotiation and JSON fallback

### Risk 2: Type Compatibility Issues
**Mitigation**: Comprehensive type mapping tests

### Risk 3: MessagePack Library Bugs
**Mitigation**: Well-tested libraries (Msgpax, python-msgpack)

## Timeline

- Phase 1-2: Core implementation (2-3 hours)
- Phase 3-4: Compatibility layer (1-2 hours)
- Phase 5-6: Testing (2-3 hours)
- Phase 7: Optimization (1-2 hours)

Total: 6-10 hours of development

## Success Metrics

1. All existing tests pass
2. 10x performance improvement in benchmarks
3. Binary data transfer without encoding
4. Seamless fallback to JSON when needed
5. No breaking changes for users

## Rollback Plan

If issues arise:
1. Config flag to force JSON protocol
2. Git revert to previous version
3. Clear communication to users
4. Fix forward with patches

## Next Steps

1. Review and approve this plan
2. Create feature branch
3. Implement Phase 1-2
4. Test core functionality
5. Implement remaining phases
6. Performance validation
7. Merge to main branch