/**
 * PSSpecifier+AltList.h - PSSpecifier 的 AltList 扩展分类
 *
 * 为 PSSpecifier 添加安全的 getter/setter 调用方法，兼容 iOS 8 和 iOS 9+ 的不同内部实现。
 */

@interface PSSpecifier (AltList)

/**
 * 判断是否拥有有效的 getter 方法
 * iOS 9+ 使用 hasValidGetter 方法，旧版本直接检查 target 和 getter
 *
 * @return YES 表示有有效的 getter
 */
- (BOOL)atl_hasValidGetter;

/**
 * 执行 getter 方法获取值
 * 优先使用 performGetter，回退到手动调用
 *
 * @return getter 返回的值
 */
- (id)atl_performGetter;

/**
 * 判断是否拥有有效的 setter 方法
 * iOS 9+ 使用 hasValidSetter 方法，旧版本直接检查 target 和 setter
 *
 * @return YES 表示有有效的 setter
 */
- (BOOL)atl_hasValidSetter;

/**
 * 执行 setter 方法设置值
 * 优先使用 performSetterWithValue:，回退到手动调用
 *
 * @param value 要设置的值
 */
- (void)atl_performSetterWithValue:(id)value;

@end
