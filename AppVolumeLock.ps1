#requires -Version 5.1
<#
.SYNOPSIS
    AppVolumeLock — запоминает громкость приложений из микшера Windows 11 и
    возвращает её, когда Windows сбрасывает уровень на 100%.

.DESCRIPTION
    Скрипт не навязывает фиксированную громкость. Он работает как память микшера:

      * при первом запуске берёт текущую громкость приложения как эталон;
      * если вы двигаете ползунок в микшере — запоминает новое значение;
      * если приложение перезапустилось и сессия создалась заново — возвращает
        сохранённое значение;
      * если Windows сбросила громкость приложения на 100% (пересоздание
        звукового потока, смена устройства, простой) — возвращает сохранённое
        значение, даже если звук в этот момент играл;
      * если сброс случился, пока у вас был открыт микшер, громкость всё равно
        доводится до сохранённой на следующем проходе.

    Ручная правка отличается от сброса Windows не по звуку, а по открытому
    микшеру: если на переднем плане «Параметры» (страница «Громкость
    микшера») или старый SndVol — любое изменение считается вашим, включая
    намеренные 100%.

    Отслеживаются ВСЕ приложения, у которых есть звук (каждое — под своим ключом,
    по имени процесса). Список Rules нужен только чтобы переопределить ключ или
    разделить сессии одного приложения (например, Discord: голос и звуки).

    У одного приложения бывает НЕСКОЛЬКО сессий в микшере. Каждая помнит свою
    громкость отдельно: ключ задаётся правилом, а состояние сессии отслеживается
    с привязкой к PID процесса — правка одного ползунка никогда не тянет за
    собой второй.

    Настройки хранятся в JSON-файле и переживают перезагрузку.

    Перечисление сессий выполняется через Core Audio API (WASAPI) на каждой
    итерации, поэтому новые сессии (например, Discord после переподключения
    к голосовому каналу) подхватываются в течение одного цикла.

.PARAMETER ListSessions
    Показать все текущие аудиосессии и сохранённые для них значения, затем выйти.
    Используйте, чтобы узнать SessionIdentifier/DisplayName для правил.

.PARAMETER Once
    Выполнить один проход и выйти (отладка).

.PARAMETER IntervalSeconds
    Интервал опроса в секундах. 0 — взять из блока $Config.

.PARAMETER LogFile
    Путь к лог-файлу.

.PARAMETER NoLog
    Не писать лог-файл.

.PARAMETER Reset
    Забыть все сохранённые значения (удалить файл памяти) и выйти.

.PARAMETER Install
    Зарегистрировать автозапуск (Планировщик заданий, при отсутствии прав —
    ярлык в папке «Автозагрузка») и выйти.

.PARAMETER Uninstall
    Удалить автозапуск и выйти.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -ListSessions

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -Once

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -Reset
#>
[CmdletBinding()]
param(
    [switch]$ListSessions,
    [switch]$Once,
    [int]$IntervalSeconds = 0,
    [string]$LogFile = "$env:LOCALAPPDATA\AppVolumeLock\app-volume-lock.log",
    [switch]$NoLog,
    [switch]$Reset,
    [switch]$Install,
    [switch]$Uninstall
)

# ============================================================================
#  КОНФИГ — правьте только этот блок
# ============================================================================
$Config = @{
    # Как часто проверять сессии (секунды). 5 — успевает ловить короткие сессии.
    IntervalSeconds = 5

    # Файл с запомненными настройками громкости.
    MemoryFile = "$env:LOCALAPPDATA\AppVolumeLock\volume-memory.json"

    # Устарело: сброс теперь отличается от ручной правки по открытому микшеру,
    # а не по длительности тишины. Параметр оставлен, чтобы старые конфиги
    # не ругались на лишний ключ.
    SilenceResetSeconds = 20

    # Правила — это ИСКЛЮЧЕНИЯ для отдельных приложений, а не белый список.
    # Всё, что не совпало ни с одним правилом, всё равно отслеживается
    # (см. TrackAllProcesses ниже) под ключом = имя процесса в нижнем регистре.
    # Применяются СВЕРХУ ВНИЗ, побеждает ПЕРВОЕ совпадение.
    #
    # Поля правила:
    #   Name                  — имя правила для лога (необязательно)
    #   Process               — имя процесса, поддерживаются маски: chrome, Discord*
    #   Key                   — ключ памяти; по умолчанию = имя процесса в нижнем
    #                           регистре. Задавайте разные Key, если у одного
    #                           приложения нужно помнить разные сессии отдельно.
    #   SessionIdentifier     — regex, которому ДОЛЖЕН соответствовать SessionIdentifier
    #   NotSessionIdentifier  — regex, которому НЕ ДОЛЖЕН соответствовать SessionIdentifier
    #   ProcessCommandLine     — regex для командной строки процесса-владельца.
    #                            Единственный способ различить сессии одного
    #                            приложения, если идентификаторы у них совпадают
    #                            (Discord: голос vs звуки уведомлений).
    #   NotProcessCommandLine — regex-исключение для командной строки процесса
    #   DisplayName           — regex для DisplayName сессии
    #   NotDisplayName        — regex-исключение для DisplayName
    #   Ignore                — $true: не трогать эти сессии вообще
    #   SkipSystemSounds      — $true по умолчанию: системные звуки не трогаем
    Rules = @(
        # --- Discord: уведомления и голос — две отдельные «памяти» --------
        # У Discord ДВЕ сессии в микшере, и у них ОДИНАКОВЫЙ SessionIdentifier
        # (в нём только путь к Discord.exe) и одинаковый
        # SessionInstanceIdentifier. Отличить их можно только по командной
        # строке процесса-владельца:
        #   --type=utility --utility-sub-type=audio.mojom.AudioService
        #       — служебный аудио-процесс: это ползунок УВЕДОМЛЕНИЙ (30%);
        #   --type=renderer
        #       — окно Discord: это ползунок ГОЛОСА собеседника (100%).
        # Проверено на слух: правка ползунка уведомлений меняет громкость
        # именно аудио-процесса.
        @{ Name = 'Discord: уведомления'; Process = 'Discord'; Key = 'discord:notifications'
           ProcessCommandLine = 'utility-sub-type=audio\.mojom\.AudioService' }
        @{ Name = 'Discord: голос'; Process = 'Discord'; Key = 'discord:voice'
           NotProcessCommandLine = 'utility-sub-type=audio\.mojom\.AudioService' }

        # --- Браузеры: несколько процессов на одно приложение -> один ключ ---
        @{ Name = 'Chrome';  Process = 'chrome*';  Key = 'chrome' }
        @{ Name = 'Edge';    Process = 'msedge*';  Key = 'edge' }
        @{ Name = 'Firefox'; Process = 'firefox*'; Key = 'firefox' }
    )

    # Отслеживать все приложения, у которых есть звук, а не только перечисленные
    # в Rules. $true — громкость запоминается для каждой программы в микшере.
    # $false — работаем строго по белому списку Rules.
    TrackAllProcesses = $true
}
# ============================================================================

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  C#: обёртка над Core Audio API (WASAPI)
# ---------------------------------------------------------------------------
$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AppVolumeLock
{
    internal enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    internal enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [Flags]
    internal enum CLSCTX : uint
    {
        INPROC_SERVER = 0x1,
        INPROC_HANDLER = 0x2,
        LOCAL_SERVER = 0x4,
        ALL = INPROC_SERVER | INPROC_HANDLER | LOCAL_SERVER
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, CLSCTX clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr propertyStore);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int sessionCount);
        [PreserveSig] int GetSession(int sessionIndex, out IAudioSessionControl session);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid eventContext);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid eventContext);
        [PreserveSig] int GetGroupingParam(out Guid groupingParam);
        [PreserveSig] int SetGroupingParam(ref Guid groupingParam, ref Guid eventContext);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2
    {
        // IAudioSessionControl
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid eventContext);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid eventContext);
        [PreserveSig] int GetGroupingParam(out Guid groupingParam);
        [PreserveSig] int SetGroupingParam(ref Guid groupingParam, ref Guid eventContext);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        // IAudioSessionControl2
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string retVal);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string retVal);
        [PreserveSig] int GetProcessId(out uint retVal);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference(bool optOut);
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, ref Guid eventContext);
        [PreserveSig] int GetMasterVolume(out float level);
        [PreserveSig] int SetMute(bool mute, ref Guid eventContext);
        [PreserveSig] int GetMute(out bool mute);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
        [PreserveSig] int GetMeteringChannelCount(out int channelCount);
        [PreserveSig] int GetChannelsPeakValues(int channelCount, [Out] float[] peakValues);
        [PreserveSig] int QueryHardwareSupport(out int hardwareSupportMask);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2
    {
        // IAudioSessionManager
        [PreserveSig] int GetAudioSessionControl(ref Guid audioSessionGuid, int streamFlags, out IAudioSessionControl sessionControl);
        [PreserveSig] int GetSimpleAudioVolume(ref Guid audioSessionGuid, int streamFlags, out ISimpleAudioVolume audioVolume);
        // IAudioSessionManager2
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
        [PreserveSig] int RegisterSessionNotification(IntPtr sessionNotification);
        [PreserveSig] int UnregisterSessionNotification(IntPtr sessionNotification);
        [PreserveSig] int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string sessionId, IntPtr duckNotification);
        [PreserveSig] int UnregisterDuckNotification(IntPtr duckNotification);
    }

    /// <summary>Снимок одной аудиосессии.</summary>
    public class SessionInfo
    {
        public uint ProcessId;
        public string ProcessName;
        public string SessionIdentifier;
        public string SessionInstanceIdentifier;
        public string DisplayName;
        public float Volume;
        public bool Muted;
        public bool IsSystemSounds;
        public int State;    // 0 = Active, 1 = Inactive, 2 = Expired
        public float Peak;   // текущий пиковый уровень 0..1
    }

    public static class AudioSessionReader
    {
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        /// <summary>
        /// PID процесса, которому принадлежит окно на переднем плане.
        /// 0 — определить не удалось. Нужен, чтобы понять, открыт ли сейчас
        /// микшер громкости (Параметры → Звук → Громкость микшера).
        /// </summary>
        public static uint GetForegroundProcessId()
        {
            try
            {
                IntPtr hwnd = GetForegroundWindow();
                if (hwnd == IntPtr.Zero) return 0;
                uint processId;
                GetWindowThreadProcessId(hwnd, out processId);
                return processId;
            }
            catch
            {
                return 0;
            }
        }

        private static T QueryInterface<T>(object comObject) where T : class
        {
            if (comObject == null) return null;
            IntPtr unknown = IntPtr.Zero;
            IntPtr iface = IntPtr.Zero;
            try
            {
                unknown = Marshal.GetIUnknownForObject(comObject);
                Guid iid = typeof(T).GUID;
                if (Marshal.QueryInterface(unknown, ref iid, out iface) != 0) return null;
                return (T)Marshal.GetObjectForIUnknown(iface);
            }
            finally
            {
                if (iface != IntPtr.Zero) Marshal.Release(iface);
                if (unknown != IntPtr.Zero) Marshal.Release(unknown);
            }
        }

        /// <summary>
        /// Перечисляет все сессии устройства воспроизведения по умолчанию.
        /// Новый enumerator на каждый вызов — поэтому новые сессии видны сразу.
        /// </summary>
        private static void ForEachSession(Action<IAudioSessionControl, IAudioSessionControl2, ISimpleAudioVolume, IAudioMeterInformation> action)
        {
            object deviceEnumeratorCom = null;
            IMMDevice device = null;
            object managerCom = null;
            IAudioSessionEnumerator sessionEnumerator = null;

            try
            {
                deviceEnumeratorCom = new MMDeviceEnumeratorComObject();
                IMMDeviceEnumerator deviceEnumerator = (IMMDeviceEnumerator)deviceEnumeratorCom;

                int hr = deviceEnumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eConsole, out device);
                if (hr < 0) throw Marshal.GetExceptionForHR(hr);

                Guid iid = typeof(IAudioSessionManager2).GUID;
                object activated;
                hr = device.Activate(ref iid, CLSCTX.ALL, IntPtr.Zero, out activated);
                if (hr < 0) throw Marshal.GetExceptionForHR(hr);
                managerCom = activated;
                IAudioSessionManager2 manager = (IAudioSessionManager2)activated;

                hr = manager.GetSessionEnumerator(out sessionEnumerator);
                if (hr < 0) throw Marshal.GetExceptionForHR(hr);

                int count;
                hr = sessionEnumerator.GetCount(out count);
                if (hr < 0) throw Marshal.GetExceptionForHR(hr);

                for (int i = 0; i < count; i++)
                {
                    IAudioSessionControl control = null;
                    IAudioSessionControl2 control2 = null;
                    ISimpleAudioVolume volume = null;
                    IAudioMeterInformation meter = null;
                    try
                    {
                        if (sessionEnumerator.GetSession(i, out control) < 0 || control == null) continue;

                        control2 = QueryInterface<IAudioSessionControl2>(control);
                        volume = QueryInterface<ISimpleAudioVolume>(control);
                        meter = QueryInterface<IAudioMeterInformation>(control);
                        if (volume == null) continue;

                        action(control, control2, volume, meter);
                    }
                    catch
                    {
                        // Сессия могла исчезнуть между вызовами — просто идём дальше.
                    }
                    finally
                    {
                        if (meter != null) Marshal.ReleaseComObject(meter);
                        if (volume != null) Marshal.ReleaseComObject(volume);
                        if (control2 != null) Marshal.ReleaseComObject(control2);
                        if (control != null) Marshal.ReleaseComObject(control);
                    }
                }
            }
            finally
            {
                if (sessionEnumerator != null) Marshal.ReleaseComObject(sessionEnumerator);
                if (managerCom != null) Marshal.ReleaseComObject(managerCom);
                if (device != null) Marshal.ReleaseComObject(device);
                if (deviceEnumeratorCom != null) Marshal.ReleaseComObject(deviceEnumeratorCom);
            }
        }

        /// <summary>Возвращает снимок всех аудиосессий.</summary>
        public static SessionInfo[] GetSessions()
        {
            List<SessionInfo> sessions = new List<SessionInfo>();

            ForEachSession(delegate(IAudioSessionControl control, IAudioSessionControl2 control2, ISimpleAudioVolume volume, IAudioMeterInformation meter)
            {
                SessionInfo info = new SessionInfo();
                info.ProcessName = String.Empty;
                info.SessionIdentifier = String.Empty;
                info.SessionInstanceIdentifier = String.Empty;
                info.DisplayName = String.Empty;

                int state;
                if (control.GetState(out state) >= 0) info.State = state;

                float level;
                if (volume.GetMasterVolume(out level) >= 0) info.Volume = level;

                bool muted;
                if (volume.GetMute(out muted) >= 0) info.Muted = muted;

                if (meter != null)
                {
                    float peak;
                    if (meter.GetPeakValue(out peak) >= 0) info.Peak = peak;
                }

                if (control2 != null)
                {
                    uint pid;
                    if (control2.GetProcessId(out pid) >= 0) info.ProcessId = pid;

                    string sid;
                    if (control2.GetSessionIdentifier(out sid) >= 0 && sid != null) info.SessionIdentifier = sid;

                    string siid;
                    if (control2.GetSessionInstanceIdentifier(out siid) >= 0 && siid != null) info.SessionInstanceIdentifier = siid;

                    if (control2.IsSystemSoundsSession() == 0) info.IsSystemSounds = true;
                }

                string displayName;
                if (control.GetDisplayName(out displayName) >= 0 && displayName != null) info.DisplayName = displayName;

                if (info.ProcessId != 0)
                {
                    try { info.ProcessName = Process.GetProcessById((int)info.ProcessId).ProcessName; }
                    catch { info.ProcessName = String.Empty; }
                }

                sessions.Add(info);
            });

            return sessions.ToArray();
        }

        /// <summary>
        /// Ставит громкость сессии с указанным SessionInstanceIdentifier.
        /// ProcessId нужен потому, что у одного приложения бывает несколько
        /// процессов с ОДИНАКОВЫМ SessionInstanceIdentifier (Discord: голос и
        /// звуки интерфейса) — без сверки PID громкость выставилась бы обоим.
        /// 1 — выставлено, 0 — сессия не найдена, -1 — ошибка COM.
        /// </summary>
        public static int SetVolumeByInstanceId(string sessionInstanceId, uint processId, float level)
        {
            if (String.IsNullOrEmpty(sessionInstanceId)) return 0;
            if (level < 0f) level = 0f;
            if (level > 1f) level = 1f;

            int result = 0;

            ForEachSession(delegate(IAudioSessionControl control, IAudioSessionControl2 control2, ISimpleAudioVolume volume, IAudioMeterInformation meter)
            {
                if (control2 == null) return;

                string siid;
                if (control2.GetSessionInstanceIdentifier(out siid) < 0 || siid == null) return;
                if (!String.Equals(siid, sessionInstanceId, StringComparison.OrdinalIgnoreCase)) return;

                if (processId != 0)
                {
                    uint pid;
                    if (control2.GetProcessId(out pid) < 0 || pid != processId) return;
                }

                Guid context = Guid.Empty;
                int hr = volume.SetMasterVolume(level, ref context);
                result = (hr >= 0) ? 1 : -1;
            });

            return result;
        }
    }
}
'@

if (-not ('AppVolumeLock.AudioSessionReader' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

# ---------------------------------------------------------------------------
#  Логирование
# ---------------------------------------------------------------------------
$script:LogPath = $LogFile
$script:RecentLogs = @{}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [switch]$Force
    )

    $now = Get-Date
    $key = "$Level|$Message"
    if (-not $Force -and $script:RecentLogs.ContainsKey($key) -and ($now - $script:RecentLogs[$key]).TotalSeconds -lt 60) {
        return
    }
    $script:RecentLogs[$key] = $now
    if ($script:RecentLogs.Count -gt 300) { $script:RecentLogs.Clear() }

    $line = '{0} [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if ($Once) { Write-Host $line }

    if (-not $NoLog) {
        try {
            $dir = Split-Path -Parent $script:LogPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
            if ((Test-Path -LiteralPath $script:LogPath) -and ((Get-Item -LiteralPath $script:LogPath).Length -gt 1MB)) {
                Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
            }
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        }
        catch {
            # Лог не должен ронять основную работу.
        }
    }
}

# ---------------------------------------------------------------------------
#  Память настроек (JSON)
# ---------------------------------------------------------------------------
$script:Memory = @{}
$script:Seen = @{}

function Import-Memory {
    $script:Memory = @{}
    if (-not (Test-Path -LiteralPath $Config.MemoryFile)) { return }

    try {
        $raw = Get-Content -LiteralPath $Config.MemoryFile -Raw -Encoding UTF8
        if (-not $raw) { return }
        $obj = $raw | ConvertFrom-Json
        if (-not $obj -or -not $obj.channels) { return }

        foreach ($prop in $obj.channels.PSObject.Properties) {
            $value = $prop.Value
            $volume = 0.0
            # JSON всегда хранит точку как разделитель, поэтому парсим инвариантно
            # (иначе в русской локали "0.3" не разберётся).
            $parsed = [double]::TryParse(
                [string]$value.volume,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$volume
            )
            if (-not $parsed) { continue }
            if ($volume -lt 0 -or $volume -gt 1) { continue }
            $script:Memory[$prop.Name] = @{
                volume     = $volume
                process    = [string]$value.process
                updatedUtc = [string]$value.updatedUtc
            }
        }
    }
    catch {
        Write-Log ("Не удалось прочитать файл памяти: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Save-Memory {
    try {
        $dir = Split-Path -Parent $Config.MemoryFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }

        $channels = @{}
        foreach ($key in $script:Memory.Keys) { $channels[$key] = $script:Memory[$key] }

        $payload = @{ version = 1; channels = $channels } | ConvertTo-Json -Depth 6
        $tmp = $Config.MemoryFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $payload, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Config.MemoryFile -Force
    }
    catch {
        Write-Log ("Не удалось сохранить файл памяти: {0}" -f $_.Exception.Message) 'ERROR'
    }
}

function Set-MemoryVolume {
    param(
        [string]$Key,
        [double]$Volume,
        [string]$ProcessName
    )

    $script:Memory[$Key] = @{
        volume     = [math]::Round($Volume, 4)
        process    = $ProcessName
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
#  Сопоставление сессии с правилом
# ---------------------------------------------------------------------------
# Командная строка процесса нужна для правил ProcessCommandLine. Запрос к WMI
# небесплатный, поэтому кэшируем ответы на время одного прохода.
$script:CmdLineCache = @{}

function Reset-CommandLineCache {
    $script:CmdLineCache = @{}
}

function Get-ProcessCommandLine {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return '' }
    if ($script:CmdLineCache.ContainsKey($ProcessId)) { return $script:CmdLineCache[$ProcessId] }

    $cmdLine = ''
    try {
        $proc = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop
        if ($proc) { $cmdLine = [string]$proc.CommandLine }
    }
    catch { $cmdLine = '' }

    $script:CmdLineCache[$ProcessId] = $cmdLine
    return $cmdLine
}

function Test-RuleMatch {
    param(
        $Session,
        [hashtable]$Rule
    )

    if ($Session.State -eq 2) { return $false }              # Expired

    $skipSystemSounds = $true
    if ($Rule.ContainsKey('SkipSystemSounds')) { $skipSystemSounds = [bool]$Rule.SkipSystemSounds }
    if ($skipSystemSounds -and $Session.IsSystemSounds) { return $false }

    if ($Rule.ContainsKey('Process') -and $Rule.Process) {
        $pattern = [string]$Rule.Process
        $name = [string]$Session.ProcessName
        if (-not (($name -like $pattern) -or (($name + '.exe') -like $pattern))) { return $false }
    }

    if ($Rule.ContainsKey('ProcessCommandLine') -and $Rule.ProcessCommandLine) {
        $cmdLine = Get-ProcessCommandLine -ProcessId ([int]$Session.ProcessId)
        if ($cmdLine -notmatch [string]$Rule.ProcessCommandLine) { return $false }
    }

    if ($Rule.ContainsKey('NotProcessCommandLine') -and $Rule.NotProcessCommandLine) {
        $cmdLine = Get-ProcessCommandLine -ProcessId ([int]$Session.ProcessId)
        if ($cmdLine -match [string]$Rule.NotProcessCommandLine) { return $false }
    }

    if ($Rule.ContainsKey('SessionIdentifier') -and $Rule.SessionIdentifier) {
        if ([string]$Session.SessionIdentifier -notmatch [string]$Rule.SessionIdentifier) { return $false }
    }

    if ($Rule.ContainsKey('NotSessionIdentifier') -and $Rule.NotSessionIdentifier) {
        if ([string]$Session.SessionIdentifier -match [string]$Rule.NotSessionIdentifier) { return $false }
    }

    if ($Rule.ContainsKey('DisplayName') -and $Rule.DisplayName) {
        if ([string]$Session.DisplayName -notmatch [string]$Rule.DisplayName) { return $false }
    }

    if ($Rule.ContainsKey('NotDisplayName') -and $Rule.NotDisplayName) {
        if ([string]$Session.DisplayName -match [string]$Rule.NotDisplayName) { return $false }
    }

    return $true
}

function Get-SessionKey {
    param(
        $Session,
        [hashtable]$Rule
    )

    if ($Rule -and $Rule.ContainsKey('Key') -and $Rule.Key) { return [string]$Rule.Key }
    if ($Session.ProcessName) { return ([string]$Session.ProcessName).ToLowerInvariant() }
    return $null
}

# ---------------------------------------------------------------------------
#  Открыт ли микшер громкости
# ---------------------------------------------------------------------------
function Test-MixerOpen {
    # Если пользователь прямо сейчас двигает ползунки в микшере, любое
    # изменение — ручная правка, даже если оно равно 100%.
    try {
        # Старый отдельный микшер (Windows 10 / классический вид):
        # процесс живёт, только пока окно открыто.
        if (Get-Process -Name 'SndVol' -ErrorAction SilentlyContinue) { return $true }

        # Активное окно. Важно смотреть именно на передний план: если
        # «Параметры» просто висят свёрнутыми/на заднем плане, это не значит,
        # что вы крутите ползунки.
        $foregroundId = [uint32][AppVolumeLock.AudioSessionReader]::GetForegroundProcessId()
        if ($foregroundId -eq 0) { return $false }

        $foreground = Get-Process -Id $foregroundId -ErrorAction SilentlyContinue
        if (-not $foreground) { return $false }

        # «Громкость микшера» в Windows 11 — это страница приложения
        # «Параметры» (SystemSettings внутри UWP-хоста ApplicationFrameHost).
        if ($foreground.ProcessName -match '(?i)^(SystemSettings|ApplicationFrameHost|SndVol)$') { return $true }

        # Ползунки громкости есть и в выпадающей панели (Win+A, клик по
        # динамику) — её рисует ShellExperienceHost/ShellHost.
        if ($foreground.ProcessName -match '(?i)^(ShellExperienceHost|ShellHost)$') { return $true }

        # Иные окна, в заголовке которых явно написано «микшер/громкость».
        if ($foreground.MainWindowTitle -match '(?i)(микшер|mixer|громкост|volume)') { return $true }
    }
    catch { }
    return $false
}

# ---------------------------------------------------------------------------
#  Один проход: сравнить микшер с памятью и разрулить расхождения
# ---------------------------------------------------------------------------
function Invoke-VolumePass {
    $fixed = 0
    $learned = 0
    $dirty = $false

    try {
        $sessions = [AppVolumeLock.AudioSessionReader]::GetSessions()
    }
    catch {
        Write-Log ("Не удалось перечислить аудиосессии: {0}" -f $_.Exception.Message) 'ERROR'
        return @{ Fixed = 0; Learned = 0 }
    }

    $now = Get-Date
    $newSeen = @{}
    Reset-CommandLineCache
    $mixerOpen = Test-MixerOpen
    $resetHits = 0

    foreach ($session in $sessions) {
        try {
            if ($session.State -eq 2) { continue }

            $rule = $null
            foreach ($candidate in $Config.Rules) {
                if (Test-RuleMatch -Session $session -Rule $candidate) {
                    $rule = $candidate
                    break
                }
            }

            if ($rule) {
                if ($rule.ContainsKey('Ignore') -and $rule.Ignore) { continue }
            }
            elseif (-not $Config.TrackAllProcesses) {
                continue
            }

            $key = Get-SessionKey -Session $session -Rule $rule
            if (-not $key) { continue }

            $appName = if ($session.ProcessName) { $session.ProcessName } else { '<pid {0}>' -f $session.ProcessId }
            $label = if ($rule -and $rule.Name) { $rule.Name } else { $appName }
            $current = [double]$session.Volume
            $instanceId = [string]$session.SessionInstanceIdentifier
            # У разных процессов одного приложения SessionInstanceIdentifier
            # может совпадать (Discord: голос и звуки), поэтому состояние
            # сессии храним вместе с PID.
            $seenKey = if ($instanceId) { $instanceId + '|' + $session.ProcessId } else { '' }
            $prev = if ($seenKey) { $script:Seen[$seenKey] } else { $null }
            $entry = $script:Memory[$key]

            if (-not $entry) {
                # Первое знакомство: берём то, что стоит в микшере сейчас.
                Set-MemoryVolume -Key $key -Volume $current -ProcessName $session.ProcessName
                $dirty = $true
                $learned++
                Write-Log ("{0}: запомнил текущую громкость {1}% (ключ «{2}»)" -f
                    $label, [math]::Round($current * 100), $key)
            }
            else {
                $remembered = [double]$entry.volume
                $diff = [math]::Abs($current - $remembered)

                # Менялась ли ИМЕННО эта сессия с прошлого прохода. Если нет,
                # значит значение в памяти могла обновить другая сессия с тем
                # же ключом — её нельзя подтягивать под себя.
                $changed = (-not $prev) -or ([math]::Abs($current - [double]$prev.Volume) -gt 0.005)

                # Прыжок ровно на 100% при сохранённом значении ниже 100% —
                # это почерк Windows: она так делает, когда звуковой поток
                # пересоздаётся, меняется устройство вывода или просыпается
                # «простаивавшая» сессия. Поэтому «звук играет» больше не
                # считается доказательством ручной правки — раньше из-за
                # этого браузер (Comet) запоминал сброшенные 100%.
                $resetToFull = ($current -ge 0.995) -and ($remembered -lt 0.995)
                $jumped = $changed -and ($diff -gt 0.005)

                $looksLikeReset = $false
                $reason = ''

                if (-not $prev) {
                    $looksLikeReset = $true
                    $reason = 'новая сессия'
                }
                elseif ($jumped -and $resetToFull) {
                    if ($mixerOpen) {
                        # Вы держите открытым микшер — значит, это ваша правка
                        # (в том числе намеренные 100%).
                        $reason = 'микшер открыт'
                    }
                    else {
                        $looksLikeReset = $true
                        $reason = 'сброс на 100%'
                        $resetHits++
                    }
                }
                elseif ($jumped) {
                    $reason = 'ручная правка в микшере'
                }
                elseif ($resetToFull -and -not $mixerOpen) {
                    # Сброс произошёл, пока микшер был открыт, или предыдущий
                    # проход не смог выставить громкость. Доводим сейчас —
                    # иначе приложение так и останется на 100%.
                    $looksLikeReset = $true
                    $reason = 'недоведённый сброс'
                }

                if ($looksLikeReset) {
                    $result = [AppVolumeLock.AudioSessionReader]::SetVolumeByInstanceId($instanceId, [uint32]$session.ProcessId, [float]$remembered)
                    if ($result -eq 1) {
                        $fixed++
                        Write-Log ("{0}: вернул сохранённую громкость {1}% (было {2}%; причина: {3})" -f
                            $label, [math]::Round($remembered * 100), [math]::Round($current * 100), $reason)
                    }
                    elseif ($result -lt 0) {
                        Write-Log ("{0}: COM-ошибка при установке громкости" -f $label) 'WARN'
                    }
                    else {
                        Write-Log ("{0}: сессия не найдена при установке (PID {1})" -f $label, $session.ProcessId) 'WARN'
                    }
                }
                elseif ($jumped) {
                    # Точно ваша правка — запоминаем.
                    Set-MemoryVolume -Key $key -Volume $current -ProcessName $session.ProcessName
                    $dirty = $true
                    $learned++
                    Write-Log ("{0}: новая настройка из микшера — запомнил {1}% (ключ «{2}»; причина: {3})" -f
                        $label, [math]::Round($current * 100), $key, $reason)
                }
            }

            # Запоминаем наблюдение для следующего прохода.
            $silentSince = $null
            $heard = $false
            if ($prev) {
                $silentSince = $prev.SilentSince
                $heard = $prev.Heard
            }

            if ($session.Peak -ge 0.0005) {
                $heard = $true
                $silentSince = $null
            }
            elseif (-not $silentSince) {
                $silentSince = $now
            }

            if ($seenKey) {
                $newSeen[$seenKey] = @{
                    State       = $session.State
                    Volume      = $current
                    Heard       = $heard
                    SilentSince = $silentSince
                }
            }
        }
        catch {
            Write-Log ("Ошибка обработки сессии PID {0}: {1}" -f $session.ProcessId, $_.Exception.Message) 'WARN'
        }
    }

    $script:Seen = $newSeen

    if ($dirty) { Save-Memory }

    # Если Windows продолжает настойчиво ставить 100%, стоит посмотреть лог:
    # возможно, у приложения пересоздаётся звуковой поток.
    if ($resetHits -ge 4) {
        Write-Log ("за проход громкость сбрасывалась {0} раз — похоже на пересоздание звуковых сессий" -f $resetHits) 'WARN'
    }

    return @{ Fixed = $fixed; Learned = $learned }
}

# ---------------------------------------------------------------------------
#  Автозапуск
# ---------------------------------------------------------------------------
$TaskName = 'AppVolumeLock'

function Install-Autostart {
    $scriptPath = $PSCommandPath
    $argumentLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath

    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentLine
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force `
            -Description 'AppVolumeLock: помнит громкость приложений и восстанавливает её после сброса Windows' | Out-Null

        Write-Host "Автозапуск: задача Планировщика «$TaskName» создана (запуск при входе в систему)."
        return
    }
    catch {
        Write-Warning ("Планировщик недоступен без прав администратора: {0}" -f $_.Exception.Message)
        Write-Host 'Пробую папку «Автозагрузка»...'
    }

    try {
        $startup = [Environment]::GetFolderPath('Startup')
        $shortcutPath = Join-Path $startup 'AppVolumeLock.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = $argumentLine
        $shortcut.WorkingDirectory = Split-Path -Parent $scriptPath
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'AppVolumeLock'
        $shortcut.Save()

        Write-Host "Автозапуск: создан ярлык $shortcutPath"
    }
    catch {
        Write-Log ("Не удалось настроить автозапуск: {0}" -f $_.Exception.Message) 'ERROR' -Force
        Write-Error ("Не удалось настроить автозапуск: {0}" -f $_.Exception.Message)
    }
}

function Uninstall-Autostart {
    $removed = $false

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Удалена задача Планировщика «$TaskName»."
        $removed = $true
    }

    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'AppVolumeLock.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "Удалён ярлык автозагрузки: $shortcutPath"
        $removed = $true
    }

    if (-not $removed) { Write-Host 'Автозапуск не был настроен.' }
}

# ---------------------------------------------------------------------------
#  Точка входа
# ---------------------------------------------------------------------------
Import-Memory

if ($Install) {
    Install-Autostart
    return
}

if ($Uninstall) {
    Uninstall-Autostart
    return
}

if ($Reset) {
    if (Test-Path -LiteralPath $Config.MemoryFile) {
        Remove-Item -LiteralPath $Config.MemoryFile -Force
        Write-Host "Память громкости очищена: $($Config.MemoryFile)"
    }
    else {
        Write-Host 'Файл памяти ещё не создан — очищать нечего.'
    }
    return
}

if ($ListSessions) {
    try {
        $sessions = [AppVolumeLock.AudioSessionReader]::GetSessions()
    }
    catch {
        Write-Error ("Не удалось перечислить сессии: {0}" -f $_.Exception.Message)
        return
    }

    Reset-CommandLineCache

    $sessions |
        Sort-Object ProcessName, ProcessId |
        ForEach-Object {
            $rule = $null
            foreach ($candidate in $Config.Rules) {
                if (Test-RuleMatch -Session $_ -Rule $candidate) { $rule = $candidate; break }
            }
            $key = Get-SessionKey -Session $_ -Rule $rule
            $remembered = $null
            if ($key -and $script:Memory.ContainsKey($key)) { $remembered = $script:Memory[$key].volume }

            $cmd = Get-ProcessCommandLine -ProcessId ([int]$_.ProcessId)
            $role = ''
            if ($cmd) {
                $mType = [regex]::Match($cmd, '--type=([^\s"]+)')
                if ($mType.Success) { $role = $mType.Groups[1].Value }
                $mSub = [regex]::Match($cmd, '--utility-sub-type=([^\s"]+)')
                if ($mSub.Success) { $role = $role + ': ' + ($mSub.Groups[1].Value -replace '\.mojom\.', '.') }
            }

            [pscustomobject]@{
                'Процесс'    = if ($_.ProcessName) { $_.ProcessName } else { '<pid ' + $_.ProcessId + '>' }
                'PID'        = $_.ProcessId
                'Громк.'     = '{0}%' -f [math]::Round($_.Volume * 100)
                'Помню'      = if ($null -ne $remembered) { '{0}%' -f [math]::Round($remembered * 100) } else { '' }
                'Ключ'       = $key
                'Правило'    = if ($rule -and $rule.Name) { $rule.Name } else { '' }
                'Роль'       = $role
                'Состояние'  = @('Active', 'Inactive', 'Expired')[[Math]::Min($_.State, 2)]
                'Sys'        = $_.IsSystemSounds
                'DisplayName'     = $_.DisplayName
            }
        } |
        Format-Table -AutoSize |
        Out-String -Width 400 |
        Write-Host

    Write-Host ('Найдено сессий: {0}; в памяти ключей: {1}' -f $sessions.Count, $script:Memory.Count)
    return
}

if ($IntervalSeconds -le 0) { $IntervalSeconds = [int]$Config.IntervalSeconds }

if ($Once) {
    $result = Invoke-VolumePass
    Write-Host ('Проход завершён: восстановлено {0}, запомнено {1}' -f $result.Fixed, $result.Learned)
    return
}

# Защита от второго экземпляра в рамках сессии пользователя.
$mutex = New-Object System.Threading.Mutex($false, 'AppVolumeLock_Mutex')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'Уже запущен другой экземпляр AppVolumeLock — выхожу.' 'WARN' -Force
    return
}

Write-Log ("AppVolumeLock запущен: интервал {0} с, правил {1}, сохранённых ключей {2}" -f
    $IntervalSeconds, $Config.Rules.Count, $script:Memory.Count) 'INFO' -Force

try {
    while ($true) {
        try {
            Invoke-VolumePass | Out-Null
        }
        catch {
            Write-Log ("Непредвиденная ошибка прохода: {0}" -f $_.Exception.Message) 'ERROR'
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
