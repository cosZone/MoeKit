// Original native Foundation transport test. No process/app/file inspection.
#import "fixture_json.h"
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>

static NSDictionary *booleanFields(BOOL value) {
    NSUInteger emptyCount = 0;
    return @{
        @"idle": FixtureJSONBoolean(value && emptyCount == 0),
        @"preferences_preserved": FixtureJSONBoolean(value),
        @"preference_marker_preserved": FixtureJSONBoolean(value == YES),
        @"automatic_checks_stored": FixtureJSONBoolean(value != NO),
        @"automatic_downloads_stored": FixtureJSONBoolean(value != NO),
        @"automatic_checks": FixtureJSONBoolean(value),
        @"automatic_downloads": FixtureJSONBoolean(value),
        @"explicit_values_stored": FixtureJSONBoolean(value),
        @"signature_verified": FixtureJSONBoolean(value == YES),
        @"cancellation_requested": FixtureJSONBoolean(value)
    };
}

int main(void) {
    @autoreleasepool {
        NSArray *cases = @[booleanFields(NO), booleanFields(YES)];
        for (NSDictionary *fields in cases) {
            for (NSNumber *value in fields.allValues) {
                if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return 2;
            }
        }
        NSDictionary *result = @{@"cases": cases, @"numeric_controls": @{@"zero": @0, @"one": @1}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        if (!data || fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF) return 3;
    }
    return 0;
}
