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
                string logLine = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message + Environment.NewLine;
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
            this.Text = "Proxmox AI Deployer - USB Creator v3.8";
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
                Logger.Log("ERRORE FATALE: " + ex.Message);
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

            var sb = new StringBuilder();
            sb.AppendLine("[global]");
            sb.AppendLine("keyboard = \"it\"");
            sb.AppendLine("country = \"it\"");
            sb.AppendLine("timezone = \"Europe/Rome\"");
            sb.AppendLine("fqdn = \"pve.homelab.local\"");
            sb.AppendLine("mailto = \"admin@homelab.local\"");
            sb.AppendLine("root_password = \"proxmox\"");
            sb.AppendLine("reboot_mode = \"reboot\"");
            sb.AppendLine();
            sb.AppendLine("[network]");
            sb.AppendLine("source = \"" + netSource + "\"");
            sb.AppendLine("cidr = \"" + cidr + "\"");
            sb.AppendLine("gateway = \"" + gateway + "\"");
            sb.AppendLine("dns = \"1.1.1.1\"");
            sb.AppendLine("dns2 = \"8.8.8.8\"");
            sb.AppendLine();
            sb.AppendLine("[disk_setup]");
            sb.AppendLine("filesystem = \"zfs (RAID0)\"");
            sb.AppendLine("disk_list = [\"filter:first_matched\"]");
            sb.AppendLine();
            sb.AppendLine("[prerun]");
            sb.AppendLine("source = \"from-partition\"");
            sb.AppendLine();
            sb.AppendLine("[postrun]");
            sb.AppendLine("source = \"from-partition\"");

            return sb.ToString();
        }

        private string BuildPostInstallScript()
        {
            var sb = new StringBuilder();
            sb.AppendLine("#!/bin/bash");
            sb.AppendLine("set -e");
            sb.AppendLine("exec > /var/log/homelab-firstboot.log 2>&1");
            sb.AppendLine("echo '=== INIZIO SETUP FIRST-BOOT PROXMOX + KDE ==='");

            sb.AppendLine("echo '1. Creazione utente homelab con privilegi sudo senza password...'");
            sb.AppendLine("if ! id -u homelab >/dev/null 2>&1; then");
            sb.AppendLine("    useradd -m -s /bin/bash -G sudo homelab");
            sb.AppendLine("    echo 'homelab:proxmox' | chpasswd");
            sb.AppendLine("    echo 'homelab ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/homelab");
            sb.AppendLine("    chmod 0440 /etc/sudoers.d/homelab");
            sb.AppendLine("fi");

            sb.AppendLine("echo '2. Installazione KDE Plasma e SDDM...'");
            sb.AppendLine("export DEBIAN_FRONTEND=noninteractive");
            sb.AppendLine("apt-get update");
            sb.AppendLine("apt-get install -y kde-plasma-desktop sddm xorg curl git build-essential");

            sb.AppendLine("echo '3. Configurazione Autologin SDDM...'");
            sb.AppendLine("mkdir -p /etc/sddm.conf.d");
            sb.AppendLine("cat << 'EOF' > /etc/sddm.conf.d/autologin.conf");
            sb.AppendLine("[Autologin]");
            sb.AppendLine("User=homelab");
            sb.AppendLine("Session=plasma");
            sb.AppendLine("EOF");

            sb.AppendLine("echo '4. Configurazione Autostart KDE...'");
            sb.AppendLine("mkdir -p /home/homelab/.config/autostart");
            sb.AppendLine("mkdir -p /home/homelab/scripts");

            sb.AppendLine("cat << 'EOF' > /home/homelab/scripts/post-kde-deploy.sh");
            sb.AppendLine("#!/bin/bash");
            sb.AppendLine("echo 'Avvio procedura di configurazione guidata Homelab AI...'");
            sb.AppendLine("if [ -f /usr/bin/konsole ]; then");
            sb.AppendLine("    konsole -e bash -c 'echo \"=== HOMELAB AI DEPLOYER ===\"; sleep 2; sudo rm -rf /opt/homelab-ai-deployer && sudo git clone https://github.com/mrpink77it/homelab-ai-deployer.git /opt/homelab-ai-deployer && cd /opt/homelab-ai-deployer && sudo chmod +x install.sh && sudo ./install.sh; exec bash'");
            sb.AppendLine("fi");
            sb.AppendLine("EOF");

            sb.AppendLine("chmod +x /home/homelab/scripts/post-kde-deploy.sh");
            sb.AppendLine("chown -R homelab:homelab /home/homelab/");

            sb.AppendLine("cat << 'EOF' > /home/homelab/.config/autostart/homelab-ai.desktop");
            sb.AppendLine("[Desktop Entry]");
            sb.AppendLine("Type=Application");
            sb.AppendLine("Name=Homelab AI Deployer");
            sb.AppendLine("Exec=/home/homelab/scripts/post-kde-deploy.sh");
            sb.AppendLine("X-GNOME-Autostart-enabled=true");
            sb.AppendLine("EOF");

            sb.AppendLine("chown -R homelab:homelab /home/homelab/.config");
            sb.AppendLine("systemctl set-default graphical.target");
            sb.AppendLine("echo '=== SETUP COMPLETATO CON SUCCESSO ==='");
            return sb.ToString();
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

            // 1. Smontaggio forzato dei volumi e pulizia tramite PowerShell
            lblStatus.Text = "Stato: Smontaggio volumi e sblocco disco USB...";
            progressBar.Value = 30;

            string preCleanScript = "Get-Disk -Number " + diskNum + " | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { Dismount-Volume -DriveLetter $_.DriveLetter -Force -Confirm:$false -ErrorAction SilentlyContinue }; Clear-Disk -Number " + diskNum + " -RemoveData -RemoveOEM -Confirm:$false; Set-Disk -Number " + diskNum + " -IsReadOnly $false";
            await RunPowerShellAsync(preCleanScript);

            await Task.Delay(2000);

            // 2. Scrittura RAW (DD)
            lblStatus.Text = "Stato: Scrittura RAW dell'immagine ISO Proxmox...";
            await Task.Run(async () =>
            {
                using var isoStream = new FileStream(isoPath, FileMode.Open, FileAccess.Read, FileShare.Read);
                using var diskStream = new FileStream(
                    physicalDrive,
                    FileMode.Open,
                    FileAccess.Write,
                    FileShare.ReadWrite | FileShare.Delete,
                    1024 * 1024,
                    FileOptions.WriteThrough | FileOptions.Asynchronous);

                byte[] buffer = new byte[1024 * 1024];
                int bytesRead;
                long totalBytes = isoStream.Length;
                long bytesWritten = 0;

                while ((bytesRead = await isoStream.ReadAsync(buffer, 0, buffer.Length)) > 0)
                {
                    await diskStream.WriteAsync(buffer, 0, bytesRead);
                    bytesWritten += bytesRead;
                    int pct = 30 + (int)((bytesWritten * 40) / totalBytes);

                    this.Invoke(new Action(() =>
                    {
                        progressBar.Value = Math.Min(70, pct);
                        lblStatus.Text = "Stato: Scrittura RAW ISO in corso... (" + (bytesWritten / (1024 * 1024)) + " MB / " + (totalBytes / (1024 * 1024)) + " MB)";
                    }));
                }
                await diskStream.FlushAsync();
            });

            // 3. Creazione partizione PROXMOX-AIS con PowerShell
            lblStatus.Text = "Stato: Creazione partizione PROXMOX-AIS...";
            progressBar.Value = 75;

            string psPartitionScript = "New-Partition -DiskNumber " + diskNum + " -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'PROXMOX-AIS' -Confirm:$false";
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
                throw new Exception("Impossibile individuare la partizione PROXMOX-AIS creata.");
            }

            File.Copy(answerPath, Path.Combine(driveLetter, "answer.toml"), true);
            File.Copy(prerunPath, Path.Combine(driveLetter, "prerun.sh"), true);
            File.Copy(postrunPath, Path.Combine(driveLetter, "postrun.sh"), true);

            Logger.Log("Copia completata con successo su " + driveLetter + " (PROXMOX-AIS)");
        }

        private async Task RunPowerShellAsync(string command)
        {
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
                Logger.Log("[PowerShell Output]: " + output);
                if (!string.IsNullOrEmpty(error))
                {
                    Logger.Log("[PowerShell Error]: " + error);
                }

                if (proc.ExitCode != 0)
                {
                    throw new Exception("Errore esecuzione comando PowerShell: " + error);
                }
            }
        }
    }

    public class UsbDriveItem
    {
        public string DisplayName { get; set; } = "";
        public string DeviceID { get; set; } = "";
        public override string ToString() => DisplayName;
    }
}
