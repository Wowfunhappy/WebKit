/*
 * Character and caret iteration over grapheme clusters built from joiners, modifiers, flags,
 * combining marks and conjoining jamo: every interior offset is inside the one cluster.
 */

#include "config.h"

#include <wtf/text/TextBreakIterator.h>

namespace TestWebKitAPI {

TEST(WTF_TextBreakIterator, EmojiCharacterAndCaret)
{
    const String clusters[] = {
        u"❤️‍\U0001FA79"_str,
        u"\U0001F3C3‍♀️"_str,
        u"\U0001F3C3\U0001F3FB‍♀️"_str,
        u"⛹\U0001F3FB‍♀️"_str,
        u"\U0001F1FA\U0001F1F8"_str,
        u"á"_str,
        u"각"_str,
    };
    const TextBreakIterator::Mode modes[] = { TextBreakIterator::CharacterMode { }, TextBreakIterator::CaretMode { } };
    for (auto& string : clusters) {
        for (auto mode : modes) {
            CachedTextBreakIterator iterator(string, { }, mode, AtomString("en"_str));
            EXPECT_TRUE(iterator.isBoundary(0));
            EXPECT_TRUE(iterator.isBoundary(string.length()));
            for (unsigned offset = 0; offset < string.length(); ++offset) {
                EXPECT_EQ(iterator.following(offset), string.length());
                // Backward queries start at Unicode code-point boundaries.
                if (!U16_IS_LEAD(string[offset]))
                    EXPECT_EQ(iterator.preceding(offset + 1), 0U);
                if (offset)
                    EXPECT_FALSE(iterator.isBoundary(offset));
            }
        }
    }
}

} // namespace TestWebKitAPI
