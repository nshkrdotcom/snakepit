# Documentation Archive

This directory contains historical documentation, design artifacts, and analysis files that are preserved for reference but are not part of the current active documentation.

## Directory Structure

### `design-process/`
Implementation plans, design documents, and stage completion reports that guided development but are no longer actively maintained:

- `bidirectional_tool_bridge_implementation_plan.md` - Original implementation plan
- `bidirectional_tool_bridge_streaming_implementation_plan.md` - Streaming implementation plan
- `bidirectional_tool_bridge_as_built.md` - As-built documentation
- `GRPC_INTEGRATION_PLAN.md` - gRPC integration roadmap
- `unified_grpc_bridge_stage0.md` - Stage 0 implementation status
- `V2_BRIDGE_EXTENSION_DESIGN.md` - Bridge extension design
- `stage0_completion_report.md` - Stage 0 completion report
- `grpc-implementation-status.md` - Implementation status tracking
- `grpc-implementation-plan.md` - Original gRPC plan
- `demo_behavior_design.md` - Demo behavior design
- `messagepack_wire_protocol_implementation.md` - MessagePack protocol design
- `SUPERTESTER_REFACTOR_PLAN.md` - Test refactoring plan
- `README_UNIFIED_GRPC_BRIDGE.md` - Unified gRPC bridge implementation notes
- `UNIFIED_EXAMPLE_DESIGN.md` - Unified showcase example design document

### `analysis/`
Historical analysis, cleanup reports, and issue assessments:

- `20251007_slop_cleanup_analysis/` - Comprehensive refactoring analysis
- `CLEANUP_20250722.md` - July cleanup analysis
- `20250717_enhanced_python_bridge_issues_and_fixes.md` - Bridge issues
- `20251007_issue_2_remaining_work.md` - Issue #2 remaining work
- `20251007_issue_2_critical_review.md` - Issue #2 critical review
- `20251007_external_process_supervision_design.md` - Supervision design
- `technical-assessment-issue-2.md` - Technical assessment
- `recommendations-issue-2.md` - Recommendations
- `systemd_cgroups_research.md` - Research notes
- `python_bridge_v2_commercial_refactoring_recommendations.md` - Refactoring recommendations
- `protocol_negotiation_fix.md` - Protocol negotiation fix
- `process_management.md` - Process management design
- `PHASE_1_COMPLETE.md` - Phase 1 completion report
- `PYTHON_CLEANUP_SUMMARY.md` - Python cleanup summary

### `specs/`
Original specification documents:

- `grpc_streaming_examples.md` - gRPC streaming examples
- `grpc_bridge_redesign.md` - Bridge redesign specs
- `testOverhaul/` - Test overhaul specifications
- `proc_mgmt/` - Process management specifications

## Why These Are Archived

These documents represent the design and development process that led to the current implementation. They are valuable for:

1. **Historical Context** - Understanding why decisions were made
2. **Future Reference** - Revisiting abandoned approaches if needed
3. **Development Process** - Showing how the architecture evolved

However, they are **not maintained** as the codebase evolves. For current documentation, refer to the files in the root directory and `docs/` (excluding `docs/archive/`).

## Current Documentation

For up-to-date documentation, see:

- [Main README](../../README.md)
- [Architecture](../../ARCHITECTURE.md)
- [Feature Documentation](../../README_*.md)
- [Active Docs](../) (excluding this archive directory)
