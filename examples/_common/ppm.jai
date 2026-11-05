write_to_image :: (bytes: [] u8, filename: string, width: u32, height: u32) {
    assert(bytes.count >= cast(s64) (width * height * 4), "write_to_image: buffer too small");

    builder: String_Builder;
    defer reset(*builder);
    append(*builder, "P6\n");
    print_to_builder(*builder, "% %\n255\n", width, height);

    pixel_count := cast(s64) (width * height);
    for i: 0..pixel_count - 1 {
        base := i * 4;
        append(*builder, bytes[base + 0]);
        append(*builder, bytes[base + 1]);
        append(*builder, bytes[base + 2]);
    }

    if write_entire_file(filename, *builder) {
        print("Wrote % (%x%)\n", filename, width, height);
    } else {
        log_error("Failed to write %\n", filename);
    }
}
