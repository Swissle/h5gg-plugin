// native_lang_plugin.m
// Single-file H5GG native plugin + loader example.
// - Exposes C API: plugin_init, plugin_call, plugin_free
// - Contains a NativePlugin loader class which uses dlopen/dlsym
// - Contains an example Objective-C plugin implementation (exported C symbols)
// Build as .dylib/.framework and load from H5GG engine using NativePlugin

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - Plugin API (C)


#ifdef __cplusplus
extern "C" {
#endif

typedef int  (*plugin_init_fn_t)(void *host_api);
typedef const char* (*plugin_call_fn_t)(const char *method, const char *json_args);
typedef void (*plugin_free_fn_t)(const char *result);

#ifdef __cplusplus
}
#endif

#pragma mark - NativePlugin loader (for engine)

// This class can live inside the H5GG engine: it loads a plugin at runtime and forwards calls.
// Usage in engine: create NativePlugin, call loadAtPath:error:, then callMethod:argsJson:
@interface NativePlugin : NSObject
@property (nonatomic, assign) void *handle;
@property (nonatomic, assign) plugin_init_fn_t initFunc;
@property (nonatomic, assign) plugin_call_fn_t callFunc;
@property (nonatomic, assign) plugin_free_fn_t freeFunc;
- (BOOL)loadAtPath:(NSString*)path error:(NSError**)err;
- (NSString*)callMethod:(NSString*)method argsJson:(NSString*)args;
@end

@implementation NativePlugin

- (BOOL)loadAtPath:(NSString*)path error:(NSError**)err {
    if (self.handle) {
        // already loaded
        return YES;
    }
    const char *cpath = [path fileSystemRepresentation];
    // RTLD_NOW to resolve symbols now. RTLD_LOCAL to keep plugin symbols local.
    void *h = dlopen(cpath, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        if (err) *err = [NSError errorWithDomain:@"NativePlugin" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:dlerror() ?: "dlopen failed"]}];
        return NO;
    }
    self.handle = h;
    self.initFunc = (plugin_init_fn_t)dlsym(h, "plugin_init");
    self.callFunc = (plugin_call_fn_t)dlsym(h, "plugin_call");
    self.freeFunc = (plugin_free_fn_t)dlsym(h, "plugin_free"); // optional

    if (!self.initFunc || !self.callFunc) {
        dlclose(h);
        self.handle = NULL;
        if (err) *err = [NSError errorWithDomain:@"NativePlugin" code:2 userInfo:@{NSLocalizedDescriptionKey: @"plugin missing required symbols (plugin_init, plugin_call)"}];
        return NO;
    }

    // Provide host_api pointer. Here we pass the loader instance pointer so plugin can callback if needed.
    void *host_api = (__bridge void*)self;
    int rv = self.initFunc(host_api);
    if (rv != 0) {
        dlclose(h);
        self.handle = NULL;
        if (err) *err = [NSError errorWithDomain:@"NativePlugin" code:3 userInfo:@{NSLocalizedDescriptionKey: @"plugin_init returned non-zero"}];
        return NO;
    }

    return YES;
}

- (NSString*)callMethod:(NSString*)method argsJson:(NSString*)args {
    if (!self.callFunc) return nil;
    const char *res = self.callFunc([method UTF8String], [args UTF8String]);
    NSString *ret = nil;
    if (res) {
        ret = [NSString stringWithUTF8String:res];
        // let plugin free its own memory if plugin_free exists
        if (self.freeFunc) {
            self.freeFunc(res);
        } else {
            free((void*)res);
        }
    }
    return ret;
}

- (void)dealloc {
    if (self.handle) {
        dlclose(self.handle);
        self.handle = NULL;
    }
}

@end

#pragma mark - Example Objective-C plugin implementation (single-file)


static void *g_host_api = NULL; // opaque host pointer
static BOOL g_plugin_initialized = NO;

#ifdef __cplusplus
extern "C" {
#endif

// Called once by the loader when the plugin is dlopened
int plugin_init(void *host_api) {
    @autoreleasepool {
        g_host_api = host_api;
        g_plugin_initialized = YES;
        // perform any plugin initialization here (load resources, etc.)
        // Return 0 for success; non-zero for failure.
        return 0;
    }
}


const char* plugin_call(const char *method, const char *json_args) {
    @autoreleasepool {
        if (!g_plugin_initialized) {
            const char *err = strdup("{\"ok\":false,\"error\":\"plugin not initialized\"}");
            return err;
        }

        NSString *m = method ? [NSString stringWithUTF8String:method] : @"";
        NSString *args = json_args && strlen(json_args) ? [NSString stringWithUTF8String:json_args] : @"{}";

        NSError *err = nil;
        NSData *data = [args dataUsingEncoding:NSUTF8StringEncoding];
        id argsObj = nil;
        if (data) {
            argsObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!argsObj || err) {
                // bad JSON
                const char *out = strdup("{\"ok\":false,\"error\":\"invalid json args\"}");
                return out;
            }
        } else {
            argsObj = @{};
        }

        NSMutableDictionary *outDict = [NSMutableDictionary dictionary];
        outDict[@"ok"] = @YES;
        outDict[@"method"] = m;

        if ([m isEqualToString:@"echo"]) {
            outDict[@"echo"] = argsObj ?: @{};
        } else if ([m isEqualToString:@"sum"]) {
            // accept numbers a and b
            double a = 0.0, b = 0.0;
            if ([argsObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = (NSDictionary*)argsObj;
                id ai = d[@"a"];
                id bi = d[@"b"];
                if (ai) a = [ai respondsToSelector:@selector(doubleValue)] ? [ai doubleValue] : 0.0;
                if (bi) b = [bi respondsToSelector:@selector(doubleValue)] ? [bi doubleValue] : 0.0;
            }
            outDict[@"sum"] = @((a + b));
        } else if ([m isEqualToString:@"version"]) {
            outDict[@"version"] = @"native_lang_plugin v1.0 (objc single-file)";
        } else {
            outDict[@"ok"] = @NO;
            outDict[@"error"] = [NSString stringWithFormat:@"unknown method '%@'", m];
        }

        NSData *outData = [NSJSONSerialization dataWithJSONObject:outDict options:0 error:&err];
        if (!outData || err) {
            const char *out = strdup("{\"ok\":false,\"error\":\"serialization failed\"}");
            return out;
        }
        // allocate malloc'd C string; caller will free via plugin_free (if available) or free()
        size_t len = (size_t)[outData length];
        char *c = (char*)malloc(len + 1);
        memcpy(c, [outData bytes], len);
        c[len] = '\0';
        return c;
    }
}

// Free function: host should call this to free returned strings (optional)
void plugin_free(const char *result) {
    if (result) free((void*)result);
}

#ifdef __cplusplus
}
#endif

#pragma mark - Simple local test harness (only active if you compile as executable)


#ifdef BUILD_AS_TEST_EXECUTABLE
int main(int argc, char *argv[]) {
    // call plugin_init and plugin_call directly (we're linked into the binary)
    int r = plugin_init(NULL);
    printf("plugin_init -> %d\n", r);
    const char *res = plugin_call("version", "{}");
    if (res) {
        printf("version: %s\n", res);
        plugin_free(res);
    }
    const char *r2 = plugin_call("sum", "{\"a\":5.5,\"b\":2.25}");
    if (r2) {
        printf("sum result: %s\n", r2);
        plugin_free(r2);
    }
    return 0;
}
#endif

/*
  End of single-file plugin + loader.
*/

