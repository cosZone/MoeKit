// Original CI-only JSON transport helper. Never linked into MoeKit.
#ifndef MOEKIT_SPARKLE_FIXTURE_JSON_H
#define MOEKIT_SPARKLE_FIXTURE_JSON_H

#import <Foundation/Foundation.h>

// C comparisons/logical expressions have type int, even when their operands
// are BOOL. Box them explicitly as CFBoolean-backed NSNumber values so JSON
// consumers receive true/false rather than the integers 1/0.
static inline NSNumber *FixtureJSONBoolean(BOOL value) {
    return [NSNumber numberWithBool:value];
}

#endif
