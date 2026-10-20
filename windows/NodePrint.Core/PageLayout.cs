namespace NodePrint.Core;

/// <summary>Where a page lands on the paper, in device pixels. <see cref="Width"/> and <see cref="Height"/> are the
/// drawn box after any rotation; the page itself is rendered at <see cref="RenderWidth"/> × <see cref="RenderHeight"/>.</summary>
public readonly record struct Placement(int X, int Y, int Width, int Height, bool Rotated)
{
    public int RenderWidth => Rotated ? Height : Width;
    public int RenderHeight => Rotated ? Width : Height;
}

public static class PageLayout
{
    public const double LabelWidthInches = 4;
    public const double LabelLengthInches = 6;

    public static bool IsLandscape(double pageWidth, double pageHeight) => pageWidth > pageHeight;

    /// <summary>A label page: landscape pages turn 90° clockwise, then fit inside the area and centre.</summary>
    public static Placement Label(double pageWidth, double pageHeight, int areaWidth, int areaHeight)
    {
        bool rotated = IsLandscape(pageWidth, pageHeight);
        return rotated
            ? Fit(pageHeight, pageWidth, areaWidth, areaHeight, true)
            : Fit(pageWidth, pageHeight, areaWidth, areaHeight, false);
    }

    /// <summary>A document page keeps its orientation (the paper is turned to match) and fits inside the area.</summary>
    public static Placement Document(double pageWidth, double pageHeight, int areaWidth, int areaHeight) =>
        Fit(pageWidth, pageHeight, areaWidth, areaHeight, false);

    /// <summary>Label size in dots for a printer resolution: 812 × 1218 at 203 dpi.</summary>
    public static (int Width, int Length) LabelDots(int dpi) =>
        ((int)Math.Round(LabelWidthInches * dpi), (int)Math.Round(LabelLengthInches * dpi));

    private static Placement Fit(double width, double height, int areaWidth, int areaHeight, bool rotated)
    {
        int w, h;
        if (width * areaHeight >= height * areaWidth)
        {
            w = areaWidth;
            h = Math.Clamp((int)Math.Round(height * areaWidth / width), 1, areaHeight);
        }
        else
        {
            h = areaHeight;
            w = Math.Clamp((int)Math.Round(width * areaHeight / height), 1, areaWidth);
        }
        return new Placement((areaWidth - w) / 2, (areaHeight - h) / 2, w, h, rotated);
    }
}
