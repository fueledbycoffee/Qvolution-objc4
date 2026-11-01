// CATALYST_MSGLOG ownership check (fleet-fixes review F2). Our own code; run in a fresh prefix.
//   MsgLogTest inventory   -- CATALYST_MSGLOG=1 and an inventory listing the runtime's images
//   MsgLogTest none        -- CATALYST_MSGLOG=1 and a missing inventory
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/stat.h>

static int checks, failed;
static void expect(int ok, const char *what)
{
	checks++;
	if (!ok) failed++;
	printf("%s %s\n", ok ? "ok  " : "FAIL", what);
}

static char logbuf[1 << 20];
static size_t loglen(void)
{
	char path[64];
	snprintf(path, sizeof(path), "/tmp/catalyst-msgs-%d", (int)getpid());
	int fd = open(path, O_RDONLY);
	if (fd < 0) return 0;
	ssize_t n = read(fd, logbuf, sizeof(logbuf) - 1);
	close(fd);
	if (n < 0) n = 0;
	logbuf[n] = 0;
	return (size_t)n;
}
static int has(size_t from, const char *needle) { return strstr(logbuf + from, needle) != NULL; }

@interface MLLocal : NSObject
- (int)mlLocalMethod;
@end
@implementation MLLocal
- (int)mlLocalMethod { return 1; }
@end

@interface NSObject (MLCategory)
- (int)mlCategoryMethod;
@end
@implementation NSObject (MLCategory)
- (int)mlCategoryMethod { return 2; }
@end

static BOOL replacementAllowsWeakReference(id self, SEL _cmd) { return YES; }

int main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "ring") == 0) {
		[NSObject instancesRespondToSelector:@selector(mlRingProbe)];
		[NSObject instancesRespondToSelector:@selector(mlRingProbe)];
		MLLocal *local = [[MLLocal alloc] init];
		[local mlLocalMethod];
		void (*dump)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "catalyst_objc_dump_messages");
		expect(dump != NULL, "ring dump entry point available");
		if (dump) dump();
		loglen();
		const char *needle = "+ NSObject NSObject instancesRespondToSelector: libobjc.A.dylib\n";
		const char *first = strstr(logbuf, needle);
		expect(first && strstr(first + strlen(needle), needle), "ring retains repeated sends without cache fill");
		expect(!has(0, "mlLocalMethod") && !has(0, "MLLocal"), "ring excludes non-inventory implementation");
		expect(has(0, "--- last sends"), "ring dump emitted");
		printf("HARNESS done: %d checks, %d failed\n", checks, failed);
		return failed != 0;
	}
	int inventory = argc > 1 && strcmp(argv[1], "inventory") == 0;
	NSObject *plain = [[NSObject alloc] init];

	// 1. own library: NSObject's class method is implemented in libobjc
	[NSObject instancesRespondToSelector:@selector(mlNothing)];
	// 2. a class of this executable
	MLLocal *local = [[MLLocal alloc] init];
	[local mlLocalMethod];
	// 3. receiver from this executable, implementation in libobjc
	[MLLocal instancesRespondToSelector:@selector(mlNothing)];
	// 4. a category from this executable on a libobjc class
	[plain mlCategoryMethod];
	// 5. a runtime-created class with a block IMP, and one inheriting libobjc's method
	Class dyn = objc_allocateClassPair([NSObject class], "MLDynamic", 0);
	class_addMethod(dyn, @selector(mlDynamicMethod), imp_implementationWithBlock(^int(id s) { return 3; }), "i@:");
	objc_registerClassPair(dyn);
	id d = [[dyn alloc] init];
	((int (*)(id, SEL))objc_msgSend)(d, @selector(mlDynamicMethod));
	[dyn instancesRespondToSelector:@selector(mlOther)];
	size_t before = loglen();
	// 6. one of libobjc's methods given an implementation from this executable
	Method m = class_getInstanceMethod([NSObject class], @selector(allowsWeakReference));
	size_t mark = loglen();
	method_setImplementation(m, (IMP)replacementAllowsWeakReference);
	((BOOL (*)(id, SEL))objc_msgSend)(plain, @selector(allowsWeakReference));
	size_t after = loglen();

	if (inventory) {
		expect(has(0, "+ NSObject NSObject instancesRespondToSelector: libobjc.A.dylib\n"), "own method recorded with image name");
		expect(!has(0, "mlLocalMethod"), "executable class not recorded");
		expect(has(0, "+ other NSObject instancesRespondToSelector: libobjc.A.dylib\n"), "non-inventory receiver written as other");
		expect(!has(0, "MLLocal") && !has(0, "MLDynamic"), "non-inventory class names never written");
		expect(!has(0, "mlCategoryMethod"), "category IMP from executable not recorded");
		expect(!has(0, "mlDynamicMethod"), "runtime-created class not recorded");
		expect(has(0, "allowsWeakReference libobjc.A.dylib") && mark >= before, "libobjc IMP of allowsWeakReference recorded before replacement");
		expect(!has(mark, "allowsWeakReference"), "replaced IMP from executable not recorded");
		expect(!has(0, "# CATALYST_MSGLOG: no usable inventory"), "inventory accepted");
	} else {
		expect(has(0, "# CATALYST_MSGLOG: no usable inventory at "), "missing inventory announced");
		const char *nl = strchr(logbuf, '\n');
		expect(nl && nl[1] == 0, "nothing else recorded without inventory");
	}
	(void)after;
	Dl_info info;
	struct stat st;
	if (dladdr((void *)objc_getClass, &info) && info.dli_fname && stat(info.dli_fname, &st) == 0)
		printf("libobjc: %s size %lld\n", info.dli_fname, (long long)st.st_size);
	printf("--- message log ---\n%s--- end ---\n", logbuf);
	printf("HARNESS done: %d checks, %d failed\n", checks, failed);
	return failed != 0;
}
