using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.Windows.ApplicationModel.DynamicDependency;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Controls;
using Windows.Win32.UI.WindowsAndMessaging;

namespace NodePrint.App;

/// <summary>Finds Microsoft's Windows App Runtime, which the app uses instead of carrying its own copy, and offers to
/// download and install it when it is missing. Runs before anything else of the Windows App SDK can be used, so it
/// has only Win32 to show itself with and its own few strings.</summary>
internal static unsafe class RuntimeSetup
{
    public const string DownloadUrl = "https://aka.ms/windowsappsdk/2.5/latest/windowsappruntimeinstall-x64.exe";

    private const int InstallButton = 100;
    private static Task<string?>? installing;

    public static bool Ensure()
    {
        if (TryStart(Bootstrap.InitializeOptions.None)) return true;
        if (!AskAndInstall()) return false;
        // Whatever happened, the bootstrapper's own message is the last word if the runtime still cannot be found.
        return TryStart(Bootstrap.InitializeOptions.OnNoMatch_ShowUI);
    }

    private static bool TryStart(Bootstrap.InitializeOptions options) => Bootstrap.TryInitialize(
        Microsoft.WindowsAppSDK.Release.MajorMinor, Microsoft.WindowsAppSDK.Release.VersionTag,
        new PackageVersion(Microsoft.WindowsAppSDK.Runtime.Version.UInt64), options, out _);

    private static bool AskAndInstall()
    {
        var text = Text.ForCurrentCulture();
        int clicked = 0;
        fixed (char* title = "NODE Print", instruction = text.Instruction, content = text.Question, install = text.Install)
        {
            var button = new TASKDIALOG_BUTTON { nButtonID = InstallButton, pszButtonText = install };
            var config = new TASKDIALOGCONFIG
            {
                cbSize = (uint)sizeof(TASKDIALOGCONFIG),
                dwFlags = TASKDIALOG_FLAGS.TDF_ENABLE_HYPERLINKS | TASKDIALOG_FLAGS.TDF_CALLBACK_TIMER |
                    TASKDIALOG_FLAGS.TDF_ALLOW_DIALOG_CANCELLATION,
                dwCommonButtons = TASKDIALOG_COMMON_BUTTON_FLAGS.TDCBF_CANCEL_BUTTON,
                pszWindowTitle = title,
                pszMainInstruction = instruction,
                pszContent = content,
                cButtons = 1,
                pButtons = &button,
                nDefaultButton = InstallButton,
                pfCallback = &Callback,
            };
            if (PInvoke.TaskDialogIndirect(&config, &clicked, null, null).Failed) return false;
        }
        if (clicked != InstallButton || installing is null) return false;
        string? error = installing.Result;
        if (error is null) return true;
        PInvoke.MessageBox(default, string.Format(text.Failed, error, DownloadUrl), "NODE Print",
            MESSAGEBOX_STYLE.MB_OK | MESSAGEBOX_STYLE.MB_ICONERROR);
        return false;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static HRESULT Callback(HWND dialog, uint notification, WPARAM wParam, LPARAM lParam, nint data)
    {
        switch ((TASKDIALOG_NOTIFICATIONS)notification)
        {
            case TASKDIALOG_NOTIFICATIONS.TDN_HYPERLINK_CLICKED:
                Process.Start(new ProcessStartInfo(new string((char*)lParam.Value)) { UseShellExecute = true });
                break;
            case TASKDIALOG_NOTIFICATIONS.TDN_BUTTON_CLICKED when (int)wParam.Value == InstallButton:
                if (installing is { IsCompleted: true }) return HRESULT.S_OK;
                if (installing is null)
                {
                    installing = Task.Run(InstallAsync);
                    PInvoke.SendMessage(dialog, (uint)TASKDIALOG_MESSAGES.TDM_ENABLE_BUTTON, InstallButton, 0);
                    PInvoke.SendMessage(dialog, (uint)TASKDIALOG_MESSAGES.TDM_SET_MARQUEE_PROGRESS_BAR, 1, 0);
                    PInvoke.SendMessage(dialog, (uint)TASKDIALOG_MESSAGES.TDM_SET_PROGRESS_BAR_MARQUEE, 1, 0);
                    fixed (char* progress = Text.ForCurrentCulture().Installing)
                    {
                        PInvoke.SendMessage(dialog, (uint)TASKDIALOG_MESSAGES.TDM_SET_ELEMENT_TEXT,
                            (nuint)TASKDIALOG_ELEMENTS.TDE_CONTENT, (nint)progress);
                    }
                }
                return HRESULT.S_FALSE;
            case TASKDIALOG_NOTIFICATIONS.TDN_TIMER when installing is { IsCompleted: true }:
                PInvoke.SendMessage(dialog, (uint)TASKDIALOG_MESSAGES.TDM_CLICK_BUTTON, InstallButton, 0);
                break;
        }
        return HRESULT.S_OK;
    }

    /// <summary>Downloads Microsoft's installer and runs it quietly; null when it worked, else what went wrong.</summary>
    private static async Task<string?> InstallAsync()
    {
        try
        {
            string installer = Path.Combine(Path.GetTempPath(), "WindowsAppRuntimeInstall-x64.exe");
            var result = PInvoke.URLDownloadToFile(null, DownloadUrl, installer, 0, null);
            if (result.Failed) return Marshal.GetExceptionForHR(result.Value)?.Message ?? $"0x{result.Value:X8}";
            using var process = Process.Start(installer, "--quiet");
            await process.WaitForExitAsync();
            return process.ExitCode == 0 ? null : $"exit code {process.ExitCode}";
        }
        catch (Exception e)
        {
            return e.Message;
        }
    }

    private sealed record Text(string Instruction, string Question, string Install, string Installing, string Failed)
    {
        public static Text ForCurrentCulture() => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName switch
        {
            "zh" => new(
                "需要安装 Windows App Runtime",
                "NODE Print 用的是微软的 Windows App Runtime 2.5，这台电脑上还没有。现在下载安装吗？（约 120 MB）\n\n" +
                $"也可以<a href=\"{DownloadUrl}\">自己下载</a>，装好后再打开 NODE Print。",
                "下载并安装",
                "正在下载并安装 Windows App Runtime…",
                "Windows App Runtime 没有装上：{0}\n\n可以从 {1} 下载后自己安装。"),
            "es" => new(
                "Hace falta Windows App Runtime",
                "NODE Print usa Windows App Runtime 2.5 de Microsoft, que no está en este equipo. ¿Descargarlo e " +
                $"instalarlo ahora? (unos 120 MB)\n\nTambién puede <a href=\"{DownloadUrl}\">descargarlo usted</a> y " +
                "volver a abrir NODE Print.",
                "Descargar e instalar",
                "Descargando e instalando Windows App Runtime…",
                "No se pudo instalar Windows App Runtime: {0}\n\nPuede descargarlo desde {1} e instalarlo usted."),
            _ => new(
                "Windows App Runtime is needed",
                "NODE Print uses Microsoft's Windows App Runtime 2.5, which is not on this computer yet. Download and " +
                $"install it now? (about 120 MB)\n\nOr <a href=\"{DownloadUrl}\">download it yourself</a> and open NODE " +
                "Print again.",
                "Download and install",
                "Downloading and installing Windows App Runtime…",
                "Windows App Runtime could not be installed: {0}\n\nYou can download it from {1} and install it yourself."),
        };
    }
}
