// Regression fixture: class realization after a replacement default malloc zone.
// A process may register its own zone and make it the default with the public
// malloc_zone_register/malloc_zone_unregister calls; Chromium's allocator does
// this, and its size callback reports block capacity larger than the request.
// malloc_size(3) allows that ("at least as large ... and may be larger").
//
// Build without ARC, x86_64 only (i386 uses the old runtime, which has no
// realized-class validation):
//   clang -fno-objc-arc padded-zone-class-data.m -lobjc -o padded-zone-class-data
// Run one mode per fresh process; each prints a PASS line or aborts:
//   exact      capacity == request: accepted (control)
//   padded     capacity == request + 8: accepted
//   undersized capacity == request - 8: rejected, "corrupt data pointer" abort
//   unowned    zone disowns its blocks (size 0): rejected, same abort
#include <objc/runtime.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef NDEBUG
#error This fixture requires assertions enabled, including their checked calls
#endif
#if !defined(__LP64__)
#error The realized-class validation exists only in the new (LP64) runtime
#endif

__attribute__((objc_root_class))
@interface QVPaddedZoneRoot { Class isa; }
@end
@implementation QVPaddedZoneRoot
@end
@interface QVPaddedZoneLeaf : QVPaddedZoneRoot
@end
@implementation QVPaddedZoneLeaf
@end

// Bump arena: a 16-byte header before each block records its capacity.
static _Alignas(16) unsigned char arena[1 << 20];
static size_t used;
static long adjust;     // capacity = request + adjust
static int disown;      // size() returns 0 for our own blocks

static int owns(const void *p) {
    return (const unsigned char *)p >= arena && (const unsigned char *)p < arena + sizeof(arena);
}
static size_t zsize(malloc_zone_t *z, const void *p) {
    (void)z;
    if (!owns(p) || disown) return 0;
    return ((const size_t *)p)[-2];
}
static void *zmalloc(malloc_zone_t *z, size_t n) {
    (void)z;
    size_t need = 16 + ((n + 15) & ~(size_t)15);
    if (used + need > sizeof(arena)) return NULL;
    unsigned char *p = arena + used + 16;
    used += need;
    ((size_t *)p)[-2] = (size_t)((long)n + adjust);
    return p;
}
static void *zcalloc(malloc_zone_t *z, size_t c, size_t n) {
    if (n && c > SIZE_MAX / n) return NULL;
    void *p = zmalloc(z, c * n);
    if (p) memset(p, 0, c * n);   // arena is static, but blocks are never reused anyway
    return p;
}
static void *zvalloc(malloc_zone_t *z, size_t n) { (void)z; (void)n; return NULL; }
static void zfree(malloc_zone_t *z, void *p) { (void)z; (void)p; }
static void *zrealloc(malloc_zone_t *z, void *p, size_t n) {
    void *q = zmalloc(z, n);
    if (q && p) {
        size_t old = ((size_t *)p)[-2];
        memcpy(q, p, old < n ? old : n);
    }
    return q;
}
static void zdestroy(malloc_zone_t *z) { (void)z; }
static size_t igood(malloc_zone_t *z, size_t n) { (void)z; return n; }
static boolean_t icheck(malloc_zone_t *z) { (void)z; return 1; }
static void inop(malloc_zone_t *z) { (void)z; }
static void iprint(malloc_zone_t *z, boolean_t v) { (void)z; (void)v; }
static void ilog(malloc_zone_t *z, void *a) { (void)z; (void)a; }
static void istats(malloc_zone_t *z, malloc_statistics_t *s) { (void)z; memset(s, 0, sizeof(*s)); }

static struct malloc_introspection_t introspect = {
    .good_size = igood, .check = icheck, .print = iprint, .log = ilog,
    .force_lock = inop, .force_unlock = inop, .statistics = istats,
};
static malloc_zone_t zone = {
    .size = zsize, .malloc = zmalloc, .calloc = zcalloc, .valloc = zvalloc,
    .free = zfree, .realloc = zrealloc, .destroy = zdestroy,
    .zone_name = "QVPaddedZone", .introspect = &introspect, .version = 6,
};

static malloc_zone_t *firstZone(void) {
    vm_address_t *zones = NULL;
    unsigned count = 0;
    kern_return_t kr = malloc_get_all_zones(mach_task_self(), NULL, &zones, &count);
    assert(kr == KERN_SUCCESS && count > 0);
    return (malloc_zone_t *)zones[0];
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp(mode, "exact")) adjust = 0;
    else if (!strcmp(mode, "padded")) adjust = 8;
    else if (!strcmp(mode, "undersized")) adjust = -8;
    else if (!strcmp(mode, "unowned")) disown = 1;
    else { fprintf(stderr, "usage: %s exact|padded|undersized|unowned\n", argv[0]); return 2; }

    // Make the fixture zone the first registered zone, which serves calloc:
    // unregistering moves the last zone into the vacated slot.
    malloc_zone_t *system = firstZone();
    malloc_zone_register(&zone);
    malloc_zone_unregister(system);
    malloc_zone_register(system);
    void *probe = calloc(1, 32);
    if (firstZone() != &zone || !owns(probe)) {
        fprintf(stderr, "SKIP: replacement zone did not become the calloc zone\n");
        return 77;
    }

    // Realizing the root realizes its metaclass, whose superclass is the
    // already-realized root: that revalidates the root's class data. The leaf
    // revalidates the root again through its superclass.
    Class leaf = objc_getClass("QVPaddedZoneLeaf");
    assert(leaf && class_getSuperclass(leaf) == objc_getClass("QVPaddedZoneRoot"));
    // objc_class is isa, superclass, a two-word cache, then the data bits:
    // the precondition is that the class data really came from this zone.
    uintptr_t bits = ((const uintptr_t *)leaf)[4];
    assert(owns((const void *)(bits & ~(uintptr_t)7)));
    assert(class_getInstanceSize(leaf) == sizeof(Class));
    printf("PASS: %s class data capacity accepted\n", mode);
    return 0;
}
