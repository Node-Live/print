using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Shapes;

namespace NodePrint.App;

internal static class Shadows
{
    /// <summary>Draws a soft shadow of <paramref name="shape"/> in <paramref name="host"/>, an empty canvas laid out
    /// right under the shape with the same size.</summary>
    public static void Attach(Canvas host, Shape shape, float blur, float offsetY, float opacity)
    {
        var compositor = ElementCompositionPreview.GetElementVisual(host).Compositor;
        var shadow = compositor.CreateDropShadow();
        shadow.BlurRadius = blur;
        shadow.Offset = new Vector3(0, offsetY, 0);
        shadow.Color = Colors.Black;
        shadow.Opacity = opacity;
        shadow.Mask = shape.GetAlphaMask();
        var visual = compositor.CreateSpriteVisual();
        visual.Shadow = shadow;
        visual.RelativeSizeAdjustment = Vector2.One;
        ElementCompositionPreview.SetElementChildVisual(host, visual);
    }
}
