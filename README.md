# h5gg-plugin
native parser for multilanguage usage via h5gg engine. 


# made for self use, you can compile yourself into a dylib and add the structure to your h5gg module to enable. 


- load like following
 NSString *pluginPath = [[NSBundle mainBundle] pathForResource:@"native_lang_plugin" ofType:@"dylib" inDirectory:@"Plugins"];
NativePlugin *p = [NativePlugin new];
NSError *err = nil;
BOOL ok = [p loadAtPath:pluginPath error:&err];
if (!ok) {
   NSLog(@"failed to load plugin: %@", err);
} else {
   NSString *res = [p callMethod:@"version" argsJson:@"{}"];
   NSLog(@"plugin returned: %@", res);
}
