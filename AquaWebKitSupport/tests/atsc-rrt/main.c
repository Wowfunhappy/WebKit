#include <gst/gst.h>
#include <gst/mpegts/mpegts.h>
#include <string.h>

static void free_segment(gpointer p) { g_boxed_free(GST_TYPE_MPEGTS_ATSC_STRING_SEGMENT, p); }
static void add_name(GPtrArray *names, const char *text)
{
    GstMpegtsAtscMultString *name = g_new0(GstMpegtsAtscMultString, 1);
    memcpy(name->iso_639_langcode, "eng", 4);
    name->segments = g_ptr_array_new_with_free_func(free_segment);
    GstMpegtsAtscStringSegment *segment = g_new0(GstMpegtsAtscStringSegment, 1);
    segment->compressed_data = (guint8 *)text;
    segment->compressed_data_size = strlen(text);
    g_ptr_array_add(name->segments, segment);
    g_ptr_array_add(names, name);
}
static void check_name(GPtrArray *names, const char *text)
{
    g_assert_cmpuint(names->len, ==, 1);
    GstMpegtsAtscMultString *name = g_ptr_array_index(names, 0);
    g_assert_cmpstr(name->iso_639_langcode, ==, "eng");
    g_assert_cmpuint(name->segments->len, ==, 1);
    GstMpegtsAtscStringSegment *segment = g_ptr_array_index(name->segments, 0);
    g_assert_cmpuint(segment->compressed_data_size, ==, strlen(text));
    g_assert(memcmp(segment->compressed_data, text, strlen(text)) == 0);
}
static guint32 crc(const guint8 *bytes, gsize length)
{
    guint32 result = 0xffffffff;
    for (gsize i = 0; i < length; ++i) {
        result ^= (guint32)bytes[i] << 24;
        for (unsigned bit = 0; bit < 8; ++bit)
            result = (result << 1) ^ ((result & 0x80000000) ? 0x04c11db7 : 0);
    }
    return result;
}
static GBytes *roundtrip(unsigned count, const char *region, const char *dimension)
{
    GstMpegtsAtscRRT *rrt = gst_mpegts_atsc_rrt_new();
    if (count) add_name(rrt->names, region);
    rrt->dimensions_defined = count;
    for (unsigned i = 0; i < count; ++i) {
        GstMpegtsAtscRRTDimension *dim = gst_mpegts_atsc_rrt_dimension_new();
        add_name(dim->names, dimension);
        dim->graduated_scale = i % 2;
        dim->values_defined = 2;
        for (unsigned j = 0; j < 2; ++j) {
            GstMpegtsAtscRRTDimensionValue *value = gst_mpegts_atsc_rrt_dimension_value_new();
            add_name(value->abbrev_ratings, j ? "PG" : "G");
            add_name(value->ratings, j ? "Parental guidance" : "General audiences");
            g_ptr_array_add(dim->values, value);
        }
        g_ptr_array_add(rrt->dimensions, dim);
    }
    const guint8 payload[] = { 1, 2, 3, 4 };
    g_ptr_array_add(rrt->descriptors, gst_mpegts_descriptor_from_custom(0x80, payload, sizeof payload));
    GstMpegtsSection *section = gst_mpegts_section_from_atsc_rrt(rrt);
    gsize length;
    guint8 *data = gst_mpegts_section_packetize(section, &length);
    g_assert(data);
    g_assert_cmpuint(crc(data, length), ==, 0);
    GstMpegtsSection *copy = gst_mpegts_section_new(0x1ffb, g_memdup2(data, length), length);
    g_assert(copy);
    const GstMpegtsAtscRRT *parsed = gst_mpegts_section_get_atsc_rrt(copy);
    g_assert(parsed);
    g_assert_cmpuint(parsed->dimensions_defined, ==, count);
    g_assert_cmpuint(parsed->dimensions->len, ==, count);
    if (count) check_name(parsed->names, region);
    for (unsigned i = 0; i < count; ++i) {
        GstMpegtsAtscRRTDimension *dim = g_ptr_array_index(parsed->dimensions, i);
        check_name(dim->names, dimension);
        g_assert_cmpuint(!!dim->graduated_scale, ==, i % 2);
        g_assert_cmpuint(dim->values_defined, ==, 2);
        g_assert_cmpuint(dim->values->len, ==, 2);
        for (unsigned j = 0; j < 2; ++j) {
            GstMpegtsAtscRRTDimensionValue *value = g_ptr_array_index(dim->values, j);
            check_name(value->abbrev_ratings, j ? "PG" : "G");
            check_name(value->ratings, j ? "Parental guidance" : "General audiences");
        }
    }
    g_assert_cmpuint(parsed->descriptors->len, ==, 1);
    GstMpegtsDescriptor *descriptor = g_ptr_array_index(parsed->descriptors, 0);
    g_assert_cmpuint(descriptor->tag, ==, 0x80);
    g_assert_cmpuint(descriptor->length, ==, sizeof payload);
    g_assert(memcmp(descriptor->data + 2, payload, sizeof payload) == 0);
    GBytes *result = g_bytes_new(data, length);
    gst_mpegts_section_unref(copy);
    gst_mpegts_section_unref(section);
    return result;
}
int main(int argc, char **argv)
{
    gst_init(&argc, &argv);
    gst_mpegts_initialize();
    for (unsigned count = 0; count <= 2; ++count) {
        for (unsigned variant = 0; variant < 2; ++variant) {
            const char *region = variant ? "R" : "Long region name";
            const char *dimension = variant ? "Long dimension name" : "D";
            GBytes *reference = roundtrip(count, region, dimension);
            for (unsigned i = 0; i < 20; ++i) {
                GBytes *again = roundtrip(count, region, dimension);
                g_assert(g_bytes_equal(reference, again));
                g_bytes_unref(again);
            }
            g_bytes_unref(reference);
        }
    }
    g_print("RRT empty/populated round trips, names, values, descriptors, CRC and deterministic output passed\n");
    return 0;
}
