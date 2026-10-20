using System.Text;

namespace NodePrint.Core;

/// <summary>Labels as raw ZPL: a 1-bit bitmap in a ^GFA field with ZPL's ASCII compression.</summary>
public static class Zpl
{
    /// <summary>Places a page rendered at the placement's drawn size (top-down BGRA, already turned) on a white
    /// label and thresholds it to packed 1-bit rows, most significant bit first, 1 where a dot prints.</summary>
    public static byte[] Pack(ReadOnlySpan<byte> bgra, Placement placement, int labelWidth, int labelLength)
    {
        int bytesPerRow = (labelWidth + 7) / 8;
        var packed = new byte[bytesPerRow * labelLength];
        int stride = placement.Width * 4;
        int top = Math.Max(placement.Y, 0), bottom = Math.Min(placement.Y + placement.Height, labelLength);
        int left = Math.Max(placement.X, 0), right = Math.Min(placement.X + placement.Width, labelWidth);
        for (int y = top; y < bottom; y++)
        {
            int row = (y - placement.Y) * stride;
            for (int x = left; x < right; x++)
            {
                int i = row + (x - placement.X) * 4;
                // 0.299 R + 0.587 G + 0.114 B < 128, in integers so every platform agrees at the boundary.
                if (299 * bgra[i + 2] + 587 * bgra[i + 1] + 114 * bgra[i] < 128_000)
                {
                    packed[y * bytesPerRow + (x >> 3)] |= (byte)(0x80 >> (x & 7));
                }
            }
        }
        return packed;
    }

    /// <summary>The ^GFA data for packed rows.</summary>
    public static string Compress(ReadOnlySpan<byte> packed, int bytesPerRow)
    {
        var data = new StringBuilder();
        char[] row = new char[bytesPerRow * 2];
        ReadOnlySpan<byte> previous = default;
        for (int start = 0; start < packed.Length; start += bytesPerRow)
        {
            var bytes = packed.Slice(start, bytesPerRow);
            if (start > 0 && bytes.SequenceEqual(previous))
            {
                data.Append(':');
                continue;
            }
            previous = bytes;
            Convert.TryToHexString(bytes, row, out _);
            for (int i = 0; i < row.Length;)
            {
                char digit = row[i];
                int end = i + 1;
                while (end < row.Length && row[end] == digit) end++;
                if (end == row.Length && digit == '0') data.Append(',');
                else if (end == row.Length && digit == 'F') data.Append('!');
                else AppendRun(data, end - i, digit);
                i = end;
            }
        }
        return data.ToString();
    }

    /// <summary>One ^XA … ^XZ block for a label of packed rows.</summary>
    public static void AppendLabel(StringBuilder job, int width, int length, ReadOnlySpan<byte> packed, int copies)
    {
        int bytesPerRow = (width + 7) / 8;
        int total = bytesPerRow * length;
        job.Append("^XA\n")
            .Append("^PW").Append(width).Append('\n')
            .Append("^LL").Append(length).Append('\n')
            .Append("^LH0,0\n")
            .Append("^FO0,0^GFA,").Append(total).Append(',').Append(total).Append(',').Append(bytesPerRow).Append(',')
            .Append(Compress(packed, bytesPerRow)).Append("^FS\n")
            .Append("^PQ").Append(copies).Append(",0,1,Y\n")
            .Append("^XZ\n");
    }

    private static void AppendRun(StringBuilder data, int count, char digit)
    {
        if (count > 1)
        {
            for (; count >= 400; count -= 400) data.Append('z');
            if (count >= 20)
            {
                data.Append((char)('g' + count / 20 - 1));
                count %= 20;
            }
            if (count > 0) data.Append((char)('G' + count - 1));
        }
        data.Append(digit);
    }
}
