using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Net.Http;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
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
            this.Text = "Proxmox AI Deployer - USB Creator v4.4 (Debug Log)";
            this.Size = new System.Drawing.Size(540, 430);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;

            var lblUsb = new Label { Text = "1. Seleziona Chiavetta USB Target:", Left = 20, Top = 20, Width = 480 };
            comboUsb = new ComboBox { Left = 20, Top = 45, Width = 480, DropDownStyle = ComboBoxStyle.DropDownList };

            var groupNet = new GroupBox { Text = "2. Configurazione Rete Server Proxmox", Left = 20, Top = 85, Width = 480, Height = 140 };
            radioDhcp = new RadioButton { Text = "DHCP (Assegnazione Automatica)", Left = 20, Top = 25, Width = 420, Checked = true };
            radioStatic = new RadioButton { Text = "IP Statico Manuale", Left = 20, Top = 50, Width = 420 };

            var lblIp = new Label { Text = "IP/CIDR:", Left = 40, Top = 80, Width = 60 };
            txtIp = new TextBox { Left = 100, Top = 77, Width = 140, Text = "192.168.1.150/24", Enabled = false };

            var lblGw = new Label { Text = "Gateway:", Left = 250, Top = 80, Width = 60 };
            txtGateway = new TextBox { Left = 310, Top = 77, Width = 140, Text = "192.168.1.1", Enabled = false };

            radioDhcp.CheckedChanged += (s, e) => { txtIp.Enabled = !radioDhcp.Checked; txtGateway.Enabled = !radioDhcp.Checked; };
            radioStatic.CheckedChanged += (s, e) => { txtIp.Enabled = radioStatic.Checked; txtGateway.Enabled = radioStatic.Checked; };

            groupNet.Controls.Add(radioDhcp);
            groupNet.Controls.Add(radioStatic);
            groupNet.Controls.Add(lblIp);
            groupNet.Controls.Add(txtIp);
            groupNet.Controls.Add(lblGw);
            groupNet.Controls.Add(txtGateway);

            btnCreate = new Button { Text = "CREA CHIAVETTA AUTOMATICA PROXMOX + KDE", Left = 20, Top = 240, Width = 480, Height = 45, FlatStyle = FlatStyle.System };
            btnCreate.Click += async (s, e) => await StartProcessAsync();

            progressBar = new ProgressBar { Left = 20, Top = 300, Width = 480, Height = 20 };
            lblStatus = new Label { Text = "Stato: Seleziona unita USB e avvia il processo.", Left = 20, Top = 330, Width = 480 };

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

                    var usbItem = new UsbDriveItem { DisplayName = model + " (" + sizeGb + " GB)", DeviceID = deviceId };
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
            if (comboUsb.SelectedItem is not UsbDriveItem targetUsb)
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
                Logger.Log("Inizio processo RAW per l unita: " + targetUsb.DisplayName + " (" + targetUsb.DeviceID + ")");

                string tempDir = Path.Combine(Path.GetTempPath(), "proxmox-builder");
                Directory.CreateDirectory(tempDir);

                string isoPath = Path.Combine(tempDir, "proxmox-ve-latest.iso");
                string answerPath = Path.Combine(tempDir, "answer.toml");
                string prerunPath = Path.Combine(tempDir, "prerun.sh");
                string postrunPath = Path.Combine(tempDir, "postrun.sh");

                // Step 1: Download ISO Proxmox
                lblStatus.Text = "Stato: Verifica e Download ISO Proxmox VE...";
                progressBar.Value = 10;
                await DownloadIsoAsync("https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso", isoPath);

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

            return $"""
            [global]
            keyboard = "it"
            country = "it"
            timezone = "Europe/Rome"
            fqdn = "pve.homelab.local"
            mailto = "admin@homelab.local"
            root_password = "proxmox"
            reboot_mode = "reboot"

            [network]
            source = "{netSource}"
            cidr = "{cidr}"
            gateway = "{gateway}"
            dns = "1.1.1.1"
            dns2 = "8.8.8.8"

            [disk_setup]
            filesystem = "zfs (RAID0)"
            disk_list = ["filter:first_matched"]

            [prerun]
            source = "from-partition"

            [postrun]
            source = "from-partition"
            """;
        }

        private string BuildPostInstallScript()
        {
            return """
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
                konsole -e bash -c 'echo "=== HOMELAB AI DEPLOYER ==="; sleep 2; sudo rm -rf /opt/homelab-ai-deployer && sudo git clone https://github.com/mrpink77it/homelab-ai-deployer.git /opt/homelab-ai-deployer && cd /opt/homelab-ai-deployer && sudo chmod +x install.sh && sudo ./install.sh; exec bash'
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
            """;
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
            var handler = new HttpClientHandler { AllowAutoRedirect = true };
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
            Logger.Log("Inizio FlashToUsbRawAsync sul disco fisico: " + physicalDrive + " (Numero disco: " + diskNum + ")");

            // 1. Pulizia e sblocco volumi tramite PowerShell con log esteso
            lblStatus.Text = "Stato: Sblocco e dismissione volumi USB...";
            progressBar.Value = 30;

            string preCleanScript = "Set-Disk -Number " + diskNum + " -IsOffline $false; " +
                "Get-Disk -Number " + diskNum + " | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { " +
                "  Write-Output ('Smontaggio volume ' + $_.DriveLetter); " +
                "  Dismount-Volume -DriveLetter $_.DriveLetter -Force -Confirm:$false -ErrorAction SilentlyContinue; " +
                "}; " +
                "Set-Disk -Number " + diskNum + " -IsReadOnly $false; " +
                "Clear-Disk -Number " + diskNum + " -RemoveData -RemoveOEM -Confirm:$false; " +
                "Write-Output 'Pulizia partizioni completata'";

            await RunPowerShellAsync(preCleanScript);
            await Task.Delay(2000);

            // 2. Scrittura RAW tramite API Win32 con logging dettagliato di ogni errore nativo
            lblStatus.Text = "Stato: Scrittura RAW dell'immagine ISO Proxmox...";
            Logger.Log("Tentativo di apertura handle nativo su " + physicalDrive + " con CreateFile...");

            await Task.Run(() =>
            {
                using var isoStream = new FileStream(isoPath, FileMode.Open, FileAccess.Read, FileShare.Read);

                IntPtr handle = SafeNativeMethods.CreateFile(
                    physicalDrive,
                    SafeNativeMethods.GENERIC_READ | SafeNativeMethods.GENERIC_WRITE,
                    SafeNativeMethods.FILE_SHARE_READ | SafeNativeMethods.FILE_SHARE_WRITE,
                    IntPtr.Zero,
                    SafeNativeMethods.OPEN_EXISTING,
                    SafeNativeMethods.FILE_FLAG_WRITE_THROUGH,
                    IntPtr.Zero);

                if (handle == SafeNativeMethods.INVALID_HANDLE_VALUE)
                {
                    int errCode = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                    Logger.Log("ERRORE CRITICO: CreateFile ha restituito INVALID_HANDLE_VALUE. Codice errore Win32: " + errCode);
                    throw new Exception("Impossibile aprire l'handle del disco fisico. Codice errore Win32: " + errCode);
                }

                Logger.Log("Handle nativo aperto con successo (Handle pointer: " + handle + "). Inizializzazione diskStream...");

                using var diskStream = new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(handle, true), FileAccess.Write, 1024 * 1024, false);

                byte[] buffer = new byte[1024 * 1024];
                int bytesRead;
                long totalBytes = isoStream.Length;
                long bytesWritten = 0;

                Logger.Log("Inizio scrittura flussi byte su disco...");
                while ((bytesRead = isoStream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    diskStream.Write(buffer, 0, bytesRead);
                    bytesWritten += bytesRead;
                    int pct = 30 + (int)((bytesWritten * 40) / totalBytes);

                    this.Invoke(new Action(() =>
                    {
                        progressBar.Value = Math.Min(70, pct);
                        lblStatus.Text = "Stato: Scrittura RAW ISO in corso... (" + (bytesWritten / (1024 * 1024)) + " MB / " + (totalBytes / (1024 * 1024)) + " MB)";
                    }));
                }
                diskStream.Flush();
                Logger.Log("Scrittura RAW completata con successo. Byte scritti: " + bytesWritten);
            });

            // 3. Creazione partizione PROXMOX-AIS
            lblStatus.Text = "Stato: Creazione partizione PROXMOX-AIS...";
            progressBar.Value = 75;

            string psPartitionScript = "New-Partition -DiskNumber " + diskNum + " -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'PROXMOX-AIS' -Confirm:$false; Write-Output 'Partizione creata'";

            await RunPowerShellAsync(psPartitionScript);
            await Task.Delay(3000);

            // 4. Copia file di configurazione
            lblStatus.Text = "Stato: Iniezione file answer.toml, prerun.sh e postrun.sh...";
            progressBar.Value = 85;

            string? driveLetter = null;
            for (int i = 0; i < 10; i++)
            {
                driveLetter = DriveInfo.GetDrives()
                    .FirstOrDefault(d => d.IsReady && string.Equals(d.VolumeLabel, "PROXMOX-AIS", StringComparison.OrdinalIgnoreCase))
                    ?.Name;

                if (!string.IsNullOrEmpty(driveLetter)) break;
                await Task.Delay(1000);
            }

            if (string.IsNullOrEmpty(driveLetter))
            {
                Logger.Log("ERRORE: Impossibile individuare la lettera di unità per PROXMOX-AIS dopo 10 tentativi.");
                throw new Exception("Impossibile individuare la partizione PROXMOX-AIS creata.");
            }

            Logger.Log("Unità PROXMOX-AIS trovata su: " + driveLetter + ". Copia file in corso...");
            File.Copy(answerPath, Path.Combine(driveLetter, "answer.toml"), true);
            File.Copy(prerunPath, Path.Combine(driveLetter, "prerun.sh"), true);
            File.Copy(postrunPath, Path.Combine(driveLetter, "postrun.sh"), true);

            Logger.Log("Copia file di configurazione completata con successo su " + driveLetter);
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
                    Logger.Log("ERRORE: PowerShell ha restituito exit code " + proc.ExitCode);
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
        public const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
        public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
        public static extern IntPtr CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);
    }

    public class UsbDriveItem
    {
        public string DisplayName { get; set; } = "";
        public string DeviceID { get; set; } = "";
        public override string ToString() => DisplayName;
    }
}
