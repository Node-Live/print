using global::System.Runtime.InteropServices;
using global::System.Runtime.InteropServices.Marshalling;
using Windows.Win32.Graphics.Direct2D;

namespace Windows.Win32.System.WinRT.Pdf;

/// <summary>Declared here instead of generated so the page goes in as the WinRT object's own pointer; the generated
/// <c>object</c> parameter would wrap the managed projection in a new COM object.</summary>
[GeneratedComInterface]
[Guid("7D9DCD91-D277-4947-8527-07A0DAEDA94A")]
internal unsafe partial interface IPdfRendererNative
{
    void RenderPageToSurface(nint pdfPage, nint surface, global::System.Drawing.Point offset, PDF_RENDER_PARAMS* renderParams);

    void RenderPageToDeviceContext(nint pdfPage, ID2D1DeviceContext deviceContext, PDF_RENDER_PARAMS* renderParams);
}
