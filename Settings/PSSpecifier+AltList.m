/**
 * PSSpecifier+AltList.m - PSSpecifier AltList 分类实现
 *
 * 实现了兼容 iOS 8 和 iOS 9+ 的 getter/setter 调用方法。
 */

#import <Foundation/Foundation.h>

/**
 * PSSpecifier 的私有接口声明
 * 暴露内部的 target、getter、setter 实例变量
 * 用于在 iOS 8 上直接调用
 */
@interface PSSpecifier : NSObject
{
@public
    id target;     /* getter/setter 的目标对象 */
    SEL getter;    /* 获取值的选择子 */
    SEL setter;    /* 设置值的选择子 */
}
- (BOOL)hasValidGetter;             /* iOS 9+：判断是否有有效的 getter */
- (id)performGetter;                /* iOS 9+：执行 getter */
- (BOOL)hasValidSetter;             /* iOS 9+：判断是否有有效的 setter */
- (void)performSetterWithValue:(id)value;  /* iOS 9+：执行 setter */
@end

#import "PSSpecifier+AltList.h"

@implementation PSSpecifier (AltList)

/**
 * 判断是否拥有有效的 getter 方法
 * 优先使用 iOS 9+ 的 hasValidGetter，回退到手动检查 target 和 getter
 *
 * @return YES 表示 target 能响应 getter 方法
 */
- (BOOL)atl_hasValidGetter
{
    /* iOS 9+：使用系统自带的 hasValidGetter 方法 */
    if([self respondsToSelector:@selector(hasValidGetter)])
    {
        return [self hasValidGetter];
    }
    else
    {
        /* iOS 8：手动检查 getter 和 target 是否存在且有效 */
        if(getter && target)
        {
            return [target respondsToSelector:getter];
        }
        else
        {
            return NO;
        }
    }
}

/**
 * 执行 getter 方法获取值
 * 优先使用 iOS 9+ 的 performGetter，回退到通过 objc_msgSend 手动调用
 *
 * @return getter 返回的值，失败返回 nil
 */
- (id)atl_performGetter
{
    /* iOS 9+：使用系统自带的 performGetter 方法 */
    if([self respondsToSelector:@selector(performGetter)])
    {
        return [self performGetter];
    }
    else
    {
        /* iOS 8：手动调用 target 的 getter 方法 */
        if([self atl_hasValidGetter])
        {
            /* 使用 methodForSelector 获取函数指针并调用，返回 mutableCopy 确保可变性 */
            return [((id (*)(id, SEL, id))[target methodForSelector:getter])(target, getter, self) mutableCopy];
        }
        return nil;
    }
}

/**
 * 判断是否拥有有效的 setter 方法
 * 优先使用 iOS 9+ 的 hasValidSetter，回退到手动检查 target 和 setter
 *
 * @return YES 表示 target 能响应 setter 方法
 */
- (BOOL)atl_hasValidSetter
{
    /* iOS 9+：使用系统自带的 hasValidSetter 方法 */
    if([self respondsToSelector:@selector(hasValidSetter)])
    {
        return [self hasValidSetter];
    }
    else
    {
        /* iOS 8：手动检查 setter 和 target 是否存在且有效 */
        if(setter && target)
        {
            return [target respondsToSelector:setter];
        }
        else
        {
            return NO;
        }
    }
}

/**
 * 执行 setter 方法设置值
 * 优先使用 iOS 9+ 的 performSetterWithValue:，回退到通过 objc_msgSend 手动调用
 *
 * @param value 要设置的值
 */
- (void)atl_performSetterWithValue:(id)value
{
    /* iOS 9+：使用系统自带的 performSetterWithValue: 方法 */
    if([self respondsToSelector:@selector(performSetterWithValue:)])
    {
        [self performSetterWithValue:value];
    }
    else
    {
        /* iOS 8：手动调用 target 的 setter 方法，参数为 value 和 self */
        if([self atl_hasValidSetter])
        {
            /* 使用 methodForSelector 获取函数指针并调用，传递 value 和 specifier 两个参数 */
            ((void (*)(id, SEL, id, id))[target methodForSelector:setter])(target, setter, value, self);
        }
    }
}

@end
