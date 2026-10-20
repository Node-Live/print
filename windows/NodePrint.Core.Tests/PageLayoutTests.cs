namespace NodePrint.Core.Tests;

public sealed class PageLayoutTests
{
    [Fact]
    public void A_4_by_6_portrait_page_fills_the_label()
    {
        Assert.Equal(new Placement(0, 0, 812, 1218, false), PageLayout.Label(288, 432, 812, 1218));
    }

    [Fact]
    public void A_landscape_label_page_turns_and_fills_the_label()
    {
        var placement = PageLayout.Label(432, 288, 812, 1218);

        Assert.Equal(new Placement(0, 0, 812, 1218, true), placement);
        Assert.Equal((1218, 812), (placement.RenderWidth, placement.RenderHeight));
    }

    [Fact]
    public void A_letter_page_on_a_label_keeps_its_aspect_and_centres()
    {
        // 8.5 × 11 into 812 × 1218: the width binds, 1051 dots tall, 83 dots above and below.
        Assert.Equal(new Placement(0, 83, 812, 1051, false), PageLayout.Label(612, 792, 812, 1218));
    }

    [Fact]
    public void A_wide_landscape_label_page_turns_then_centres_across()
    {
        // 11 × 4 in turned is 4 × 11 in: the length binds, 443 dots wide.
        Assert.Equal(new Placement(184, 0, 443, 1218, true), PageLayout.Label(792, 288, 812, 1218));
    }

    [Fact]
    public void A_document_page_keeps_its_orientation()
    {
        // A landscape letter page on landscape letter paper at 300 dpi is not turned.
        Assert.Equal(new Placement(0, 0, 3300, 2550, false), PageLayout.Document(792, 612, 3300, 2550));
    }

    [Fact]
    public void An_a4_page_fits_inside_the_letter_printable_area_and_centres()
    {
        // A4 is taller than letter for its width: the height binds and it centres across.
        Assert.Equal(new Placement(90, 0, 2369, 3350, false), PageLayout.Document(595.28, 841.89, 2550, 3350));
    }
}
