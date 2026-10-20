using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Shapes;

namespace NodePrint.App;

internal static class Shadows
{
    /// <summary>Draws soft shadows of <paramref name="shape"/> in <paramref name="host"/>, an empty canvas laid out right
    /// under the shape with the same size; each layer is a blur radius, a downward offset and an opacity.</summary>
    public static void Attach(Canvas host, Shape shape, params (float Blur, float OffsetY, float Opacity)[] layers)
    {
        var compositor = ElementCompositionPreview.GetElementVisual(host).Compositor;
        var container = compositor.CreateContainerVisual();
        container.RelativeSizeAdjustment = Vector2.One;
        var mask = shape.GetAlphaMask();
        foreach (var (blur, offsetY, opacity) in layers)
        {
            var shadow = compositor.CreateDropShadow();
            shadow.BlurRadius = blur;
            shadow.Offset = new Vector3(0, offsetY, 0);
            shadow.Color = Colors.Black;
            shadow.Opacity = opacity;
            shadow.Mask = mask;
            var visual = compositor.CreateSpriteVisual();
            visual.Shadow = shadow;
            visual.RelativeSizeAdjustment = Vector2.One;
            container.Children.InsertAtTop(visual);
        }
        ElementCompositionPreview.SetElementChildVisual(host, container);
    }
}
