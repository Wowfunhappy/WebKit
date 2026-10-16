// NSDateComponentsFormatter against the examples Apple's NSDateComponentsFormatter.h gives, in en_US: each
// units style's "1h 10m" case, and maximumUnitCount's "1h 10m 30s" / "10m 30s" cases. WebCore's media-control
// duration (units style Full, hour/minute/second, at most two units) is one of them. SpellOut agrees with the
// unit's grammatical gender in fr_FR, de_DE and ru_RU, and the unit's plural form with the number in ru_RU;
// those expectations are CLDR's data in Apple's ICU: each unit's gender and name patterns (French "heure" is
// feminine, written "{0}\u00A0heure"), the locale's %spellout-cardinal-<gender> rules ("une", "eine", "одна",
// "две"), and German's two-unit list pattern "{0} und {1}". The locale is the argument.
#import <Foundation/Foundation.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

static int failures;

static void expect(NSInteger style, NSUInteger allowedUnits, NSInteger maximumUnitCount, NSTimeInterval interval, NSString *expected)
{
    NSDateComponentsFormatter *formatter = [[[NSDateComponentsFormatter alloc] init] autorelease];
    formatter.unitsStyle = style;
    formatter.allowedUnits = allowedUnits;
    formatter.maximumUnitCount = maximumUnitCount;
    NSString *actual = [formatter stringFromTimeInterval:interval];
    printf("  style %ld, %g s, at most %ld units: \"%s\"\n", (long)style, interval, (long)maximumUnitCount, [actual UTF8String]);
    if (![actual isEqualToString:expected]) {
        printf("  FAIL: expected \"%s\"\n", [expected UTF8String]);
        ++failures;
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) {
            printf("  FAIL: usage: %s en_US|fr_FR|de_DE|ru_RU\n", argv[0]);
            return 1;
        }
        // The current locale is the AppleLocale preference, set here for this process only.
        NSString *requested = [NSString stringWithUTF8String:argv[1]];
        CFPreferencesSetAppValue(CFSTR("AppleLocale"), (CFStringRef)requested, kCFPreferencesCurrentApplication);
        if (![[[NSLocale currentLocale] localeIdentifier] isEqualToString:requested]) {
            printf("  FAIL: the current locale is %s, not %s\n", [[[NSLocale currentLocale] localeIdentifier] UTF8String], argv[1]);
            return 1;
        }

        NSUInteger hourMinute = NSCalendarUnitHour | NSCalendarUnitMinute;
        NSUInteger hourMinuteSecond = hourMinute | NSCalendarUnitSecond;
        NSUInteger minuteSecond = NSCalendarUnitMinute | NSCalendarUnitSecond;
        NSInteger spellOut = NSDateComponentsFormatterUnitsStyleSpellOut;
        if ([requested isEqualToString:@"fr_FR"]) {
            expect(spellOut, hourMinute, 0, 60 * 60, @"Une\u00A0heure");
            expect(spellOut, minuteSecond, 0, 1, @"Une\u00A0seconde");
            return failures ? 1 : 0;
        }
        if ([requested isEqualToString:@"de_DE"]) {
            expect(spellOut, hourMinute, 0, 60 * 60, @"Eine Stunde");
            expect(spellOut, hourMinute, 0, 62 * 60, @"Eine Stunde und zwei Minuten");
            return failures ? 1 : 0;
        }
        if ([requested isEqualToString:@"ru_RU"]) {
            expect(spellOut, minuteSecond, 0, 1, @"Одна секунда");
            expect(spellOut, minuteSecond, 0, 2 * 60, @"Две минуты");
            expect(spellOut, minuteSecond, 0, 5 * 60, @"Пять минут");
            return failures ? 1 : 0;
        }
        if (![requested isEqualToString:@"en_US"]) {
            printf("  FAIL: no expectations for %s\n", argv[1]);
            return 1;
        }
        NSTimeInterval oneHourTenMinutes = 70 * 60;
        expect(NSDateComponentsFormatterUnitsStylePositional, hourMinute, 0, oneHourTenMinutes, @"1:10");
        expect(NSDateComponentsFormatterUnitsStyleAbbreviated, hourMinute, 0, oneHourTenMinutes, @"1h 10m");
        expect(NSDateComponentsFormatterUnitsStyleShort, hourMinute, 0, oneHourTenMinutes, @"1 hr, 10 min");
        expect(NSDateComponentsFormatterUnitsStyleFull, hourMinute, 0, oneHourTenMinutes, @"1 hour, 10 minutes");
        expect(NSDateComponentsFormatterUnitsStyleSpellOut, hourMinute, 0, oneHourTenMinutes, @"One hour, ten minutes");
        expect(NSDateComponentsFormatterUnitsStyleBrief, hourMinute, 0, oneHourTenMinutes, @"1hr 10min");

        expect(NSDateComponentsFormatterUnitsStyleAbbreviated, hourMinuteSecond, 0, 70 * 60 + 30, @"1h 10m 30s");
        expect(NSDateComponentsFormatterUnitsStyleAbbreviated, hourMinuteSecond, 2, 70 * 60 + 30, @"1h 10m");
        expect(NSDateComponentsFormatterUnitsStyleAbbreviated, hourMinuteSecond, 0, 10 * 60 + 30, @"10m 30s");
        expect(NSDateComponentsFormatterUnitsStyleAbbreviated, hourMinuteSecond, 2, 10 * 60 + 30, @"10m 30s");
    }
    return failures ? 1 : 0;
}
