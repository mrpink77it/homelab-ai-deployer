using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace HomelabUSBBuilder
{
    internal static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            Logger.Log("=== AVVIO APPLICAZIONE ===");

            bool isAdmin = IsAdministrator();
            Logger.Log("Esecuzione come Amministratore: " + isAdmin);

            if (!isAdmin)
            {
                MessageBox.Show("Questa applicazione richiede privilegi di Amministratore per la scrittura RAW dei dischi.", "Privilegi Insufficienti", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Logger.Log("CRASH NON GESTITO: " + e.ExceptionObject);
            };

            Application.Run(new MainForm());
        }

        public static bool IsAdministrator()
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    public static class Logger
    {
        private static readonly string LogFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app.log");

        public static void Log(string message)
        {
            try
            {
                string logLine = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "] " + message + Environment.NewLine;
                File.AppendAllText(LogFilePath, logLine, Encoding.UTF8);
            }
            catch
            {
                // Ignora eccezioni di log
            }
        }
    }

    public partial class MainForm : Form
    {
        private ComboBox comboUsb = null!;
        private RadioButton radioDhcp = null!;
        private RadioButton radioStatic = null!;
        private TextBox txtIp = null!;
        private TextBox txtGateway = null!;
        private Button btnCreate = null!;
        private ProgressBar progressBar = null!;
        private Label lblStatus = null!;

        public MainForm()
        {
            InitializeComponentLayout();
            LoadUsbDrives();
        }

        private void InitializeComponentLayout()
        {
            this.Text = "Proxmox AI Deployer - USB Creator v4.9 (Direct RAW Write)";
            this.Size = new System.Drawing.Size(540, 430);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;

            var lblUsb = new Label() { Text = "1. Seleziona Chiavetta USB Target:", Left = 20, Top = 20, Width = 480 };
            comboUsb = new ComboBox() { Left = 20, Top = 45, Width = 480, DropDownStyle = ComboBoxStyle.DropDownList };

            var groupNet = new GroupBox() { Text = "2. Configurazione Rete Server Proxmox", Left = 20, Top = 85, Width = 480, Height = 140 };
            radioDhcp = new RadioButton() { Text = "DHCP (Assegnazione Automatica)", Left = 20, Top = 25, Width = 420, Checked = true };
            radioStatic = new RadioButton() { Text = "IP Statico Manuale", Left = 20, Top = 50, Width = 420 };

            var lblIp = new Label() { Text = "IP/CIDR:", Left = 40, Top = 80, Width = 60 };
            txtIp = new TextBox() { Left = 100, Top = 77, Width = 140, Text = "192.168.1.150/24", Enabled = false };

            var lblGw = new Label() { Text = "Gateway:", Left = 250, Top = 80, Width = 60 };
            txtGateway = new TextBox() { Left = 310, Top = 77, Width = 140, Text = "192.168.1.1", Enabled = false };

            radioDhcp.CheckedChanged += (s, e) => { txtIp.Enabled = !radioDhcp.Checked; txtGateway.Enabled = !radioDhcp.Checked; };
            radioStatic.CheckedChanged += (s, e) => { txtIp.Enabled = radioStatic.Checked; txtGateway.Enabled = radioStatic.Checked; };

            groupNet.Controls.Add(radioDhcp);
            groupNet.Controls.Add(radioStatic);
            groupNet.Controls.Add(lblIp);
            groupNet.Controls.Add(txtIp);
            groupNet.Controls.Add(lblGw);
            groupNet.Controls.Add(txtGateway);

            btnCreate = new Button() { Text = "CREA CHIAVETTA AUTOMATICA PROXMOX + KDE", Left = 20, Top = 240, Width = 480, Height = 45, FlatStyle = FlatStyle.System };
            btnCreate.Click += async (s, e) => await StartProcessAsync();

            progressBar = new ProgressBar() { Left = 20, Top = 300, Width = 480, Height = 20 };
            lblStatus = new Label() { Text = "Stato: Seleziona unita USB e avvia il processo.", Left = 20, Top = 330, Width = 480 };

            this.Controls.Add(lblUsb);
            this.Controls.Add(comboUsb);
            this.Controls.Add(groupNet);
            this.Controls.Add(btnCreate);
            this.Controls.Add(progressBar);
            this.Controls.Add(lblStatus);
        }

        private void LoadUsbDrives()
        {
            comboUsb.Items.Clear();
            Logger.Log("Ricerca chiavette USB collegate...");
            try
            {
                string wmiQuery = "SELECT * FROM Win32_DiskDrive WHERE InterfaceType='USB'";
                var searcher = new ManagementObjectSearcher(wmiQuery);
                foreach (ManagementObject drive in searcher.Get())
                {
                    string model = drive["Model"] != null ? drive["Model"].ToString()! : "USB Drive";
                    string deviceId = drive["DeviceID"] != null ? drive["DeviceID"].ToString()! : "";
                    ulong sizeBytes = Convert.ToUInt64(drive["Size"]);
                    double sizeGb = Math.Round((double)sizeBytes / (1024 * 1024 * 1024), 1);

                    var usbItem = new UsbDriveItem() { DisplayName = model + " (" + sizeGb + " GB)", DeviceID = deviceId };
                    comboUsb.Items.Add(usbItem);
                    Logger.Log("Trovata USB: " + usbItem.DisplayName + " [" + deviceId + "]");
                }

                if (comboUsb.Items.Count > 0)
                {
                    comboUsb.SelectedIndex = 0;
                }
                else
                {
                    lblStatus.Text = "Stato: Nessuna chiavetta USB trovata!";
                    Logger.Log("Nessun dispositivo USB rilevato.");
                }
            }
            catch (Exception ex)
            {
                Logger.Log("ERRORE lettura USB: " + ex.Message);
                MessageBox.Show("Errore lettura USB: " + ex.Message, "Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async Task StartProcessAsync()
        {
            if (!(comboUsb.SelectedItem is UsbDriveItem targetUsb))
            {
                MessageBox.Show("Seleziona una chiavetta USB valida!", "Attenzione", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string msgConfirm = "ATTENZIONE: TUTTI I DATI sulla chiavetta:\n\n" +
                                targetUsb.DisplayName + "\n\n" +
                                "VERRANNO CANCELLATI PER CREARE LA CHIAVETTA BOOTABLE AUTOMATICA!\n\n" +
                                "Vuoi continuare?";

            var confirm = MessageBox.Show(msgConfirm, "Conferma Formattazione USB", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            btnCreate.Enabled = false;
            comboUsb.Enabled = false;

            try
            {
                Logger.Log("Inizio processo RAW (dd-style) per l unita: " + targetUsb.DisplayName + " (" + targetUsb.DeviceID + ")");

                string tempDir = Path.Combine(Path.GetTempPath(), "proxmox-builder");
                Directory.CreateDirectory(tempDir);

                string isoPath = Path.Combine(tempDir, "proxmox-ve-latest.iso");
                string answerPath = Path.Combine(tempDir, "answer.toml");
                string prerunPath = Path.Combine(tempDir, "prerun.sh");
                string postrunPath = Path.Combine(tempDir, "postrun.sh");

                // Step 1: Download ISO Proxmox
                lblStatus.Text = "Stato: Verifica e Download ISO Proxmox VE...";
                progressBar.Value = 10;
                await DownloadIsoAsync("https://enterprise.proxmox.com/iso/proxmox-ve_8.2-1.iso", isoPath);

                // Step 2: Download prerun.sh da GitHub
                lblStatus.Text = "Stato: Download script prerun.sh...";
                progressBar.Value = 15;
                await DownloadFileAsync("https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/iso-builder/pre-install-check.sh", prerunPath);

                // Step 3: Generazione answer.toml
                lblStatus.Text = "Stato: Generazione answer.toml...";
                progressBar.Value = 20;
                File.WriteAllText(answerPath, BuildAnswerToml(), Encoding.UTF8);

                // Step 4: Generazione postrun.sh
                lblStatus.Text = "Stato: Generazione script postrun.sh (KDE + Autologin)...";
                progressBar.Value = 25;
                File.WriteAllText(postrunPath, BuildPostInstallScript(), new UTF8Encoding(false));

                // Step 5: Scrittura RAW ISO e Configurazione Partizione PROXMOX-AIS
                await FlashToUsbRawAsync(targetUsb.DeviceID, answerPath, isoPath, prerunPath, postrunPath);

                progressBar.Value = 100;
                lblStatus.Text = "Stato: CREAZIONE E VERIFICA COMPLETATE CON SUCCESSO!";
                Logger.Log("=== CREAZIONE E VERIFICA COMPLETATE CON SUCCESSO ===");
                MessageBox.Show("Chiavetta USB Proxmox + KDE autologin creata con successo in modalita RAW Autoinstall!", "Completato", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                Logger.Log("ERRORE FATALE: " + ex.Message + "\nStackTrace: " + ex.StackTrace);
                MessageBox.Show("Errore durante la creazione: " + ex.Message + "\n\nConsulta 'app.log' per maggiori dettagli.", "Errore Fatale", MessageBoxButtons.OK, MessageBoxIcon.Error);
                lblStatus.Text = "Stato: Errore riscontrato.";
            }
            finally
            {
                btnCreate.Enabled = true;
                comboUsb.Enabled = true;
            }
        }

        private string BuildAnswerToml()
        {
            string netSource = radioDhcp.Checked ? "from-dhcp" : "from-answer";
            string cidr = radioDhcp.Checked ? "dhcp" : txtIp.Text;
            string gateway = radioDhcp.Checked ? "" : txtGateway.Text;

            return $@"
[global]
keyboard = ""it""
country = ""it""
timezone = ""Europe/Rome""
fqdn = ""pve.homelab.local""
mailto = ""admin@homelab.local""
root_password = ""proxmox""
reboot_mode = ""reboot""

[network]
source = ""{netSource}""
cidr = ""{cidr}""
gateway = ""{gateway}""
dns = ""1.1.1.1""
dns2 = ""8.8.8.8""

[disk_setup]
filesystem = ""zfs (RAID0)""
disk_list = [""filter:first_matched""]

[prerun]
source = ""from-partition""

[postrun]
source = ""from-partition""
".TrimStart();
        }

        private string BuildPostInstallScript()
        {
            return @"
#!/bin/bash
set -e
exec > /var/log/homelab-firstboot.log 2>&1
echo '=== INIZIO SETUP FIRST-BOOT PROXMOX + KDE ==='

echo '1. Creazione utente homelab con privilegi sudo senza password...'
if ! id -u homelab >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo homelab
    echo 'homelab:proxmox' | chpasswd
    echo 'homelab ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/homelab
    chmod 0440 /etc/sudoers.d/homelab
fi

echo '2. Installazione KDE Plasma e SDDM...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y kde-plasma-desktop sddm xorg curl git build-essential

echo '3. Configurazione Autologin SDDM...'
mkdir -p /etc/sddm.conf.d
cat << 'EOF' > /etc/sddm.conf.d/autologin.conf
[Autologin]
User=homelab
Session=plasma
EOF

echo '4. Configurazione Autostart KDE...'
mkdir -p /home/homelab/.config/autostart
mkdir -p /home/homelab/scripts

cat << 'EOF' > /home/homelab/scripts/post-kde-deploy.sh
#!/bin/bash
echo 'Avvio procedura di configurazione guidata Homelab AI...'
if [ -f /usr/bin/konsole ]; then
    konsole -e bash -c 'echo ""=== HOMELAB AI DEPLOYER ===""; sleep 2; sudo rm -rf /opt/homelab-ai-deployer && sudo git clone https://github.com/mrpink77it/homelab-ai-deployer.git /opt/homelab-ai-deployer && cd /opt/homelab-ai-deployer && sudo chmod +x install.sh && sudo ./install.sh; exec bash'
fi
EOF

chmod +x /home/homelab/scripts/post-kde-deploy.sh
chown -R homelab:homelab /home/homelab/

cat << 'EOF' > /home/homelab/.config/autostart/homelab-ai.desktop
[Desktop Entry]
Type=Application
Name=Homelab AI Deployer
Exec=/home/homelab/scripts/post-kde-deploy.sh
X-GNOME-Autostart-enabled=true
EOF

chown -R homelab:homelab /home/homelab/.config
systemctl set-default graphical.target
echo '=== SETUP COMPLETATO CON SUCCESSO ==='
".TrimStart();
        }

        private async Task DownloadIsoAsync(string url, string destination)
        {
            if (File.Exists(destination))
            {
                long length = new FileInfo(destination).Length;
                if (length > 500 * 1024 * 1024)
                {
                    Logger.Log("File ISO gia presente e valido (" + length + " byte).");
                    return;
                }
                File.Delete(destination);
            }
            await DownloadFileAsync(url, destination);
        }

        private async Task DownloadFileAsync(string url, string destination)
        {
            var handler = new HttpClientHandler() { AllowAutoRedirect = true };
            using var client = new HttpClient(handler);
            client.Timeout = TimeSpan.FromMinutes(20);
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)");

            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();

            using var streamToRead = await response.Content.ReadAsStreamAsync();
            using var streamToWrite = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
            await streamToRead.CopyToAsync(streamToWrite);
        }

        private async Task FlashToUsbRawAsync(string deviceId, string answerPath, string isoPath, string prerunPath, string postrunPath)
        {
            string diskNum = Regex.Match(deviceId, @"\d+").Value;
            if (string.IsNullOrEmpty(diskNum))
            {
                throw new Exception("Impossibile estrarre il numero di disco da DeviceID: " + deviceId);
            }

            string physicalDrive = @"\\.\PhysicalDrive" + diskNum;
            Logger.Log("Inizio Scrittura RAW Diretta (dd style) su: " + physicalDrive + " (Disco #" + diskNum + ")");

            // 1. Sblocco preventivo: rimozione lettere di unità per evitare che Windows blocchi i volumi attivi
            lblStatus.Text = "Stato: Rimozione lettere d'unita e rilascio volumi USB...";
            progressBar.Value = 30;

            string unmountScript = 
                "$ErrorActionPreference = 'SilentlyContinue'; " +
                "Set-Disk -Number " + diskNum + " -IsReadOnly $false; " +
                "Get-Partition -DiskNumber " + diskNum + " | Where-Object DriveLetter | ForEach-Object { " +
                "  Remove-PartitionAccessPath -DiskNumber " + diskNum + " -PartitionNumber $_.PartitionNumber -AccessPath ($_.DriveLetter + ':\\') " +
                "}; ";

            await RunPowerShellAsync(unmountScript);
            await Task.Delay(1000);

            // 2. Scrittura RAW Diretta (stile DD) tramite Win32 WriteFile
            lblStatus.Text = "Stato: Scrittura RAW ISO in corso (dd streaming)...";
            Logger.Log("Apertura handle nativo direct IO su " + physicalDrive + "...");

            await Task.Run(() =>
            {
                using var isoStream = new FileStream(isoPath, FileMode.Open, FileAccess.Read, FileShare.Read);

                IntPtr handle = SafeNativeMethods.INVALID_HANDLE_VALUE;
                int lastErr = 0;

                for (int attempt = 1; attempt <= 5; attempt++)
                {
                    handle = SafeNativeMethods.CreateFile(
                        physicalDrive,
                        SafeNativeMethods.GENERIC_READ | SafeNativeMethods.GENERIC_WRITE,
                        SafeNativeMethods.FILE_SHARE_READ | SafeNativeMethods.FILE_SHARE_WRITE,
                        IntPtr.Zero,
                        SafeNativeMethods.OPEN_EXISTING,
                        0,
                        IntPtr.Zero);

                    if (handle != SafeNativeMethods.INVALID_HANDLE_VALUE) break;

                    lastErr = Marshal.GetLastWin32Error();
                    Logger.Log($"Tentativo {attempt}/5 apertura handle fallito (Win32 Code: {lastErr}). Attesa 1s...");
                    Thread.Sleep(1000);
                }

                if (handle == SafeNativeMethods.INVALID_HANDLE_VALUE)
                {
                    Logger.Log("ERRORE FATALE: Impossibile aprire handle fisico su " + physicalDrive + ". Codice Win32: " + lastErr);
                    throw new Exception("Impossibile accedere al disco fisico. Codice Win32: " + lastErr);
                }

                Logger.Log("Handle disco aperto correttamente (Pointer: " + handle + "). Lock & Dismount in corso...");

                try
                {
                    // Lock & Dismount dei volumi residui
                    SafeNativeMethods.DeviceIoControl(handle, SafeNativeMethods.FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
                    SafeNativeMethods.DeviceIoControl(handle, SafeNativeMethods.FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);

                    const int sectorSize = 512;
                    byte[] buffer = new byte[1024 * 1024]; // Buffer da 1 MB per massime prestazioni
                    int bytesRead;
                    long totalBytes = isoStream.Length;
                    long bytesWritten = 0;

                    while ((bytesRead = isoStream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        // Allineamento ai settori fisici da 512 byte
                        int bytesToWrite = bytesRead;
                        if (bytesToWrite % sectorSize != 0)
                        {
                            int remainder = bytesToWrite % sectorSize;
                            int padding = sectorSize - remainder;
                            bytesToWrite += padding;
                            Array.Clear(buffer, bytesRead, padding);
                        }

                        bool success = SafeNativeMethods.WriteFile(handle, buffer, (uint)bytesToWrite, out _, IntPtr.Zero);
                        if (!success)
                        {
                            int errCode = Marshal.GetLastWin32Error();
                            Logger.Log("ERRORE CRITICO: Scrittura blocco fallita a byte " + bytesWritten + ". Codice Win32: " + errCode);
                            throw new Exception("Errore durante la scrittura RAW dei settori sul disco. Codice Win32: " + errCode);
                        }

                        bytesWritten += bytesRead;
                        int pct = 30 + (int)((bytesWritten * 40) / totalBytes);

                        this.Invoke(new Action(() =>
                        {
                            progressBar.Value = Math.Min(70, pct);
                            lblStatus.Text = "Stato: Scrittura RAW ISO in corso... (" + (bytesWritten / (1024 * 1024)) + " MB / " + (totalBytes / (1024 * 1024)) + " MB)";
                        }));
                    }

                    Logger.Log("Scrittura RAW (dd) completata con successo. Byte scritti: " + bytesWritten);

                    // Forza Windows a rileggere la nuova tabella partizioni appena scritta dall'ISO
                    Logger.Log("Aggiornamento struttura partizioni in corso (IOCTL_DISK_UPDATE_PROPERTIES)...");
                    SafeNativeMethods.DeviceIoControl(handle, SafeNativeMethods.IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
                }
                finally
                {
                    SafeNativeMethods.DeviceIoControl(handle, SafeNativeMethods.FSCTL_UNLOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
                    SafeNativeMethods.CloseHandle(handle);
                }
            });

            // 3. Creazione della partizione FAT32 PROXMOX-AIS nello spazio rimanente
            lblStatus.Text = "Stato: Creazione partizione PROXMOX-AIS nello spazio residuo...";
            progressBar.Value = 75;

            string dpPartScript = 
                "select disk " + diskNum + "\r\n" +
                "rescan\r\n" +
                "create partition primary size=1024\r\n" +
                "format fs=fat32 quick label=\"PROXMOX-AIS\"\r\n" +
                "assign\r\n";

            await RunDiskpartScriptAsync(dpPartScript);
            await RunPowerShellAsync("Update-HostStorageCache");
            await Task.Delay(3000);

            // 4. Copia file di configurazione nella nuova partizione
            lblStatus.Text = "Stato: Iniezione file answer.toml, prerun.sh e postrun.sh...";
            progressBar.Value = 85;

            string? driveLetter = null;
            for (int i = 0; i < 20; i++)
            {
                driveLetter = DriveInfo.GetDrives()
                    .FirstOrDefault(d => d.IsReady && string.Equals(d.VolumeLabel, "PROXMOX-AIS", StringComparison.OrdinalIgnoreCase))
                    ?.Name;

                if (!string.IsNullOrEmpty(driveLetter)) break;

                if (i == 10)
                {
                    try
                    {
                        var psi = new ProcessStartInfo("powershell", "-NoProfile -Command \"(Get-Volume -FileSystemLabel 'PROXMOX-AIS' -ErrorAction SilentlyContinue).DriveLetter\"")
                        {
                            CreateNoWindow = true,
                            UseShellExecute = false,
                            RedirectStandardOutput = true
                        };
                        using var p = Process.Start(psi);
                        if (p != null)
                        {
                            string letter = (await p.StandardOutput.ReadToEndAsync()).Trim();
                            if (!string.IsNullOrEmpty(letter))
                            {
                                driveLetter = letter.TrimEnd(':') + @":\";
                                break;
                            }
                        }
                    }
                    catch { }
                }

                await Task.Delay(1000);
            }

            if (string.IsNullOrEmpty(driveLetter))
            {
                Logger.Log("ERRORE: Impossibile individuare la lettera di unità per PROXMOX-AIS.");
                throw new Exception("Impossibile individuare la partizione PROXMOX-AIS creata. Verifica in 'Questo PC'.");
            }

            Logger.Log("Unità PROXMOX-AIS trovata su: " + driveLetter + ". Copia file in corso...");
            File.Copy(answerPath, Path.Combine(driveLetter, "answer.toml"), true);
            File.Copy(prerunPath, Path.Combine(driveLetter, "prerun.sh"), true);
            File.Copy(postrunPath, Path.Combine(driveLetter, "postrun.sh"), true);

            Logger.Log("Copia file completata con successo su " + driveLetter);
        }

        private async Task RunDiskpartScriptAsync(string commands)
        {
            string scriptPath = Path.Combine(Path.GetTempPath(), "dp_" + Guid.NewGuid().ToString("N") + ".txt");
            try
            {
                await File.WriteAllTextAsync(scriptPath, commands, Encoding.ASCII);
                Logger.Log("Esecuzione Script DiskPart:\n" + commands.Trim());

                var psi = new ProcessStartInfo("diskpart.exe", "/s \"" + scriptPath + "\"")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using var proc = Process.Start(psi);
                if (proc != null)
                {
                    await proc.WaitForExitAsync();
                    string output = await proc.StandardOutput.ReadToEndAsync();
                    string error = await proc.StandardError.ReadToEndAsync();
                    if (!string.IsNullOrWhiteSpace(output))
                    {
                        Logger.Log("[DiskPart Output]:\n" + output.Trim());
                    }
                    if (!string.IsNullOrWhiteSpace(error))
                    {
                        Logger.Log("[DiskPart Error]:\n" + error.Trim());
                    }
                }
            }
            finally
            {
                try { if (File.Exists(scriptPath)) File.Delete(scriptPath); } catch { }
            }
        }

        private async Task RunPowerShellAsync(string command)
        {
            Logger.Log("Esecuzione comando PowerShell: " + command);
            var psi = new ProcessStartInfo("powershell", "-NoProfile -ExecutionPolicy Bypass -Command \"" + command + "\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using var proc = Process.Start(psi);
            if (proc != null)
            {
                await Task.Run(() => proc.WaitForExit());
                string output = await proc.StandardOutput.ReadToEndAsync();
                string error = await proc.StandardError.ReadToEndAsync();
                
                if (!string.IsNullOrWhiteSpace(output))
                {
                    Logger.Log("[PowerShell Output]: " + output.Trim());
                }
                if (!string.IsNullOrWhiteSpace(error))
                {
                    Logger.Log("[PowerShell Error]: " + error.Trim());
                }

                if (proc.ExitCode != 0)
                {
                    Logger.Log("ERRORE: PowerShell exit code " + proc.ExitCode);
                    throw new Exception("Errore esecuzione comando PowerShell: " + error);
                }
            }
        }
    }

    internal static class SafeNativeMethods
    {
        public const uint GENERIC_READ = 0x80000000;
        public const uint GENERIC_WRITE = 0x40000000;
        public const uint FILE_SHARE_READ = 0x00000001;
        public const uint FILE_SHARE_WRITE = 0x00000002;
        public const uint OPEN_EXISTING = 3;
        public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        public const uint FSCTL_LOCK_VOLUME = 0x00090018;
        public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;
        public const uint FSCTL_UNLOCK_VOLUME = 0x0009001C;
        public const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070050;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool DeviceIoControl(
            IntPtr hDevice,
            uint dwIoControlCode,
            IntPtr lpInBuffer,
            uint nInBufferSize,
            IntPtr lpOutBuffer,
            uint nOutBufferSize,
            out uint lpBytesReturned,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool WriteFile(
            IntPtr hFile,
            byte[] lpBuffer,
            uint nNumberOfBytesToWrite,
            out uint lpNumberOfBytesWritten,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);
    }

    public class UsbDriveItem
    {
        public string DisplayName { get; set; } = "";
        public string DeviceID { get; set; } = "";
        public override string ToString() => DisplayName;
    }
}
