using System.Text;
using System.Text.Json;

namespace NodePrint.Core.Tests;

public sealed class ZplTests
{
    public static TheoryData<string> Vectors() =>
        [.. Directory.GetFiles(Path.Combine(AppContext.BaseDirectory, "zpl"), "*.json").Select(f => Path.GetFileName(f)).Order()];

    private static (int Width, int Length, byte[] Packed, string Data) Load(string file)
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "zpl", file)));
        var root = json.RootElement;
        byte[] packed = Convert.FromHexString(string.Concat(root.GetProperty("rows").EnumerateArray().Select(r => r.GetString())));
        return (root.GetProperty("width").GetInt32(), root.GetProperty("length").GetInt32(), packed,
            root.GetProperty("data").GetString()!);
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void Compresses_each_vector_byte_for_byte(string file)
    {
        var (width, _, packed, data) = Load(file);

        Assert.Equal(data, Zpl.Compress(packed, (width + 7) / 8));
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void Wraps_each_vector_in_the_job_template(string file)
    {
        var (width, length, packed, data) = Load(file);
        int bytesPerRow = (width + 7) / 8, total = bytesPerRow * length;
        var job = new StringBuilder();

        Zpl.AppendLabel(job, width, length, packed, 1);

        Assert.Equal(
            $"^XA\n^PW{width}\n^LL{length}\n^LH0,0\n^FO0,0^GFA,{total},{total},{bytesPerRow},{data}^FS\n^PQ1,0,1,Y\n^XZ\n",
            job.ToString());
    }

    [Fact]
    public void Prints_copies_with_PQ()
    {
        var job = new StringBuilder();

        Zpl.AppendLabel(job, 8, 1, [0x00], 7);

        Assert.Contains("^PQ7,0,1,Y\n", job.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void A_dot_prints_only_below_luminance_128()
    {
        byte[] page = [127, 127, 127, 255, /**/ 128, 128, 128, 255, /**/ 255, 255, 255, 255, /**/ 0, 0, 0, 255];

        var packed = Zpl.Pack(page, 16, new Placement(0, 0, 4, 1, false), 8, 1);

        Assert.Equal([0b1001_0000], packed);
    }

    [Fact]
    public void Places_the_page_on_a_white_label()
    {
        byte[] black = new byte[2 * 2 * 4];
        for (int i = 3; i < black.Length; i += 4) black[i] = 255;

        var packed = Zpl.Pack(black, 8, new Placement(3, 1, 2, 2, false), 16, 4);

        Assert.Equal("0000" + "1800" + "1800" + "0000", Convert.ToHexString(packed));
    }

    [Fact]
    public void A_rotated_page_turns_clockwise()
    {
        // A 3 × 2 page with only its top-left pixel black lands, turned clockwise, at the top-right of a 2 × 3 box.
        byte[] page = Enumerable.Repeat((byte)255, 3 * 2 * 4).ToArray();
        page[0] = page[1] = page[2] = 0;

        var packed = Zpl.Pack(page, 12, new Placement(0, 0, 2, 3, true), 8, 3);

        Assert.Equal([0b0100_0000, 0, 0], packed);
    }
}
