# Slot log

One line per event, newest at the bottom. Times are UTC, from `date -u`. A slot is open from GO until RELEASED/CLOSED or HOLD.

Format:
- YYYY-MM-DD HH:MMZ <GO|CONDITIONAL GO|HOLD|STAGED|RELEASED|CLOSED> <service/job> <revision or image> (<PR/issue>; <what>). <who asked; owner's words if reserved>. rb <rollback>.

Examples:
- 2026-01-15 14:35Z GO PROMOTE api-00063 (PR #212; +26 catalog items). Owner: "ok to promote". coordinator read 14:35:14Z serving api-00060 100. rb api-00060.
- 2026-01-15 14:37Z RELEASED api-00063 100% (readback 14:38Z: tag removed, template == serving, unauth 401). rb api-00060.

---
