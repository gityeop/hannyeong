#include <ApplicationServices/ApplicationServices.h>
#include <stdatomic.h>

// Test-only interposition: exercise the production AX selection loop with delayed range values.
static _Atomic int remaining;
static _Atomic int injected;

void hannyeongDelayRangeReads(int count) {
    atomic_store(&remaining, count);
    atomic_store(&injected, 0);
}

int hannyeongInjectedRangeReads(void) { return atomic_load(&injected); }

static AXError delayedRangeRead(AXUIElementRef element, CFStringRef attribute,
                               CFTypeRef parameter, CFTypeRef *value) {
    if (CFEqual(attribute, kAXStringForRangeParameterizedAttribute) && atomic_load(&remaining) > 0) {
        atomic_fetch_sub(&remaining, 1);
        atomic_fetch_add(&injected, 1);
        *value = NULL;
        return kAXErrorNoValue;
    }
    return AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, value);
}

__attribute__((used)) static struct { const void *replacement; const void *original; } interpose[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)delayedRangeRead, (const void *)AXUIElementCopyParameterizedAttributeValue }
};
