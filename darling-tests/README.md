# Allocation regression

`raw-allocation.m` addresses a compiler-emitted root class directly. `raw` mode
requires it to be unrealized before allocation; exit 77 means that precondition
was not met. `lookup` mode is the control: objc_getClass realizes the class first.
Both exercise nil input, extra instance bytes, object identity and disposal.
Run each in a fresh process. This fixture excludes arm64e and 32-bit metadata.

On a Darwin-compatible development environment, link against the runtime under test:

```sh
clang -fno-objc-arc darling-tests/raw-allocation.m -lobjc -o raw-allocation
./raw-allocation raw
./raw-allocation lookup
./raw-allocation concurrent
```

For an existing native ARM64 Darling stage build, `build-isolated.rb` recompiles
all sources listed in this checkout's runtime/CMakeLists.txt. It reuses stage
compiler options and SDK/dependency libraries, so it is not a clean parent build.
It assumes the parent Ninja objc_obj target names and /work/source, /work/build
path layout. Supply absolute paths and a new output directory:

```sh
ruby darling-tests/build-isolated.rb CHECKOUT STAGE_BUILD LOCAL_SOURCE NEW_OUTPUT
```

Compile/link the fixture for ARM64 with the stage SDK/cctools linker, libobjc and
libSystem; use the complete installed root as the linker syslibroot for reexports.
Retain the stage's Darling preprocessor definitions (including DARLING and
_DARWIN_C_SOURCE) so pthread declarations use the supported symbol names.
Then run the prelinked fixture with a selected dylib override:

```sh
bash darling-tests/run-staged.sh INSTALL_ROOT FIXTURE_BINARY raw NEW_OUTPUT/libobjc.A.dylib
bash darling-tests/run-staged.sh INSTALL_ROOT FIXTURE_BINARY lookup NEW_OUTPUT/libobjc.A.dylib
bash darling-tests/run-staged.sh INSTALL_ROOT FIXTURE_BINARY concurrent NEW_OUTPUT/libobjc.A.dylib
```

The runner needs Docker and the existing darling-arm64-dev image (override with
DARLING_ARM64_IMAGE). It uses the stage runner's container capabilities, mounts
the staged install read-only, and copies the selected runtime and fixture into a
disposable prefix. It requires the fixture's PASS marker, not merely server exit
zero. No installed runtime is overwritten. Build logs remain in NEW_OUTPUT.

These helpers are standalone and not wired into objc4's Apple test harness.
Concurrent mode gates eight threads before the first allocation, checks the
class is still unrealized, then releases them to perform 1,000 allocations each.
All threads check object identity/size and dispose their instances. Assertions
must remain enabled. This is a bounded stress case, not a race-detector proof.
The raw fixture does not cover the internal root/batch/zone allocation entry points.

## Synthetic Swift metadata

Build `swift-allocation.m` with the same stage flags and libraries. It reuses
upstream's `test/swift-class-def.m`, without requiring a Swift compiler. Run it
through `run-staged.sh` with modes `swift`, `swift-replacement`, or
`swift-replacement-lookup`. Assertions must remain enabled.

`swift` exercises the real runtime's metadata callback. The callback allocates
a previously unrealized nested class, testing lock release/reentry, then realizes
its own metadata. Checks cover one callback, returned instance identity/size,
nil allocation, disposal and subsequent allocation without another callback.
The candidate passes on staged ARM64; public f3cd60dd aborts before the callback
at the allocation helper's realization assertion.

The replacement modes are currently **failing diagnostic cases**, not passing
regressions. The callback clones metadata to the heap and calls
`_objc_realizeClassFromSwift(newClass, oldClass)`. Candidate direct allocation
aborts in `addRemappedClass`. The lookup control triggers realization through
`objc_getClass` first, including for the nested class: both public and candidate
abort at the same remapping assertion, after a duplicate-name warning. Thus the
failure is reproducible through an existing upstream path independently of this
allocation change. The callback and its caller both attempt to register the
remapping. Upstream `runtime/objc-runtime-new.mm` explicitly documents only
in-place realization (`previously == cls`) and construction of a new class
(`previously == nil`) as supported by `_objc_realizeClassFromSwift`.
`realizeSwiftClass` likewise says that callback relocation is not accepted yet.
The replacement diagnostics therefore exercise an unsupported contract, not a
required passing allocation regression. They are retained to expose that limit;
do not treat replacement-class integration as validated or suppress failures.
The supported `swift` test uses in-place realization. Adding relocation support
would require a separate runtime change and is not supplied by this allocation
fix. Keeping the helper's returned class pointer follows its interface without
claiming that unsupported callback relocation now works.

These are synthetic metadata fixtures against the real Objective-C runtime,
not tests of a Swift language runtime, Swift concurrency or a Swift application.

## Replacement default zone

`padded-zone-class-data.m` registers its own malloc zone and makes it the zone
that serves `calloc`, with the public `malloc_zone_register`/`unregister` calls
(unregistering moves the last zone into the vacated slot). It then realizes a
root class and its subclass, so the root's already-realized class data is
validated against `malloc_size`. Build it for x86_64 only, without ARC, and run
one mode per fresh process:

    exact       capacity equals the request          PASS line, exit 0
    padded      capacity is the request plus 8        PASS line, exit 0
    undersized  capacity is the request minus 8       "corrupt data pointer" abort
    unowned     the zone disowns its blocks (size 0)  "corrupt data pointer" abort

Exit 77 means the zone did not become the `calloc` zone, so nothing was tested.
`padded` is the shape of Chromium's PartitionAlloc zone, which Electron apps
install at startup; before the capacity fix it aborted like `undersized`.
