// Build-time LeakSanitizer off-switch: ASan stays fully active; only leak detection is disabled.
extern "C" int __lsan_is_turned_off() { return 1; }
