using System;
using System.Diagnostics;
using System.IO;
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
            Logger.Log($"Esecuzione come Amministratore: {isAdmin}");

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Logger.Log($"CRASH NON GESTITO: {e.ExceptionObject}");
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
                string logLine = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}";
                File.AppendAllText(LogFilePath, logLine, Encoding.UTF8);
            }
            catch
            {
                // Ignora eventuali eccezioni durante la scrittura del log
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
            this.Text = "Proxmox AI Deployer - USB Creator v2.4";
            this.Size = new System.Drawing.Size(520, 420);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;

            var lblUsb = new Label { Text = "1. Seleziona Chiavetta USB Target:", Left = 20, Top = 20, Width = 460 };
            comboUsb = new ComboBox { Left = 20, Top = 45, Width = 460, DropDownStyle = ComboBoxStyle.DropDownList };

            var groupNet = new GroupBox { Text = "2. Configurazione Rete Server Proxmox", Left = 20, Top = 85, Width = 460, Height = 140 };
            radioDhcp = new RadioButton { Text = "DHCP (Assegnazione Automatica)", Left = 20, Top = 25, Width = 400, Checked = true };
            radioStatic = new RadioButton { Text = "IP Statico Manuale", Left = 20, Top = 50, Width = 400 };

            var lblIp = new Label { Text = "IP/CIDR:", Left = 40, Top = 80, Width = 60 };
            txtIp = new TextBox { Left = 100, Top = 77, Width = 140, Text = "192.168.1.150/24", Enabled = false };

            var lblGw = new Label { Text = "Gateway:", Left = 250, Top = 80, Width = 60 };
            txtGateway = new TextBox { Left = 310, Top = 77, Width = 130, Text = "192.168.1.1", Enabled = false };

            radioDhcp.CheckedChanged += (s, e) => { txtIp.Enabled = !radioDhcp.Checked; txtGateway.Enabled = !radioDhcp.Checked; };
            radioStatic.CheckedChanged += (s, e) => { txtIp.Enabled = radioStatic.Checked; txtGateway.Enabled = radioStatic.Checked; };

            groupNet.Controls.Add(radioDhcp);
            groupNet.Controls.Add(radioStatic);
            groupNet.Controls.Add(lblIp);
            groupNet.Controls.Add(txtIp);
            groupNet.Controls.Add(lblGw);
            groupNet.Controls.Add(txtGateway);

            btnCreate = new Button { Text = "CREA CHIAVETTA AUTOMATICA PROXMOX", Left = 20, Top = 240, Width = 460, Height = 45, FlatStyle = FlatStyle.System };
            btnCreate.Click += async (s, e) => await StartProcessAsync();

            progressBar = new ProgressBar { Left = 20, Top = 300, Width = 460, Height = 20 };
            lblStatus = new Label { Text = "Stato: Seleziona l'unità USB e avvia il processo.", Left = 20, Top = 330, Width = 460 };

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
                var searcher = new ManagementObjectSearcher(@"SELECT * FROM Win32_DiskDrive WHERE InterfaceType='USB'");
                foreach (ManagementObject drive in searcher.Get())
                {
                    string model = drive["Model"]?.ToString() ?? "USB Drive";
                    string deviceId = drive["DeviceID"]?.ToString() ?? "";
                    ulong sizeBytes = Convert.ToUInt64(drive["Size"]);
                    double sizeGb = Math.Round((double)sizeBytes / (1024 * 1024 * 1024), 1);

                    var usbItem = new UsbDriveItem { DisplayName = $"{model} ({sizeGb} GB)", DeviceID = deviceId };
                    comboUsb.Items.Add(usbItem);
                    Logger.Log($"Trovata USB: {usbItem.DisplayName} [{deviceId}]");
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
                Logger.Log($"ERRORE durante la lettura delle USB: {ex}");
                MessageBox.Show($"Errore lettura USB: {ex.Message}", "Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async Task StartProcessAsync()
        {
            if (comboUsb.SelectedItem is not UsbDriveItem targetUsb)
            {
                MessageBox.Show("Seleziona una chiavetta USB valida!", "Attenzione", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string msgConfirm = "ATTENZIONE: TUTTI I DATI sulla chiavetta:" + Environment.NewLine + Environment.NewLine +
                                targetUsb.DisplayName + Environment.NewLine + Environment.NewLine +
                                "VERRANNO CANCELLATI E LA CHIAVETTA VERRÀ FORMATTATA!" + Environment.NewLine + Environment.NewLine +
                                "Vuoi continuare?";

            var confirm = MessageBox.Show(msgConfirm, "Conferma Formattazione USB", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            btnCreate.Enabled = false;
            comboUsb.Enabled = false;

            try
            {
                Logger.Log($"Inizio processo per l'unità: {targetUsb.DisplayName} ({targetUsb.DeviceID})");

                string tempDir = Path.Combine(Path.GetTempPath(), "proxmox-builder");
                Directory.CreateDirectory(tempDir);
                string isoPath = Path.Combine(tempDir, "proxmox-ve-latest.iso");
                string answerPath = Path.Combine(tempDir, "answer.toml");

                // Step 1: Download ISO Proxmox VE 9.2-1
                lblStatus.Text = "Stato: Verifica e Download ISO Proxmox VE...";
                progressBar.Value = 25;
                string isoUrl = "https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso";
                
                Logger.Log($"Verifica / Download ISO da: {isoUrl}");
                await DownloadIsoAsync(isoUrl, isoPath);

                // Step 2: Generazione del file answer.toml
                lblStatus.Text = "Stato: Generazione file di risposta (answer.toml)...";
                progressBar.Value = 50;
                string answerToml = BuildAnswerToml();
                File.WriteAllText(answerPath, answerToml, Encoding.UTF8);
                Logger.Log($"File answer.toml creato in: {answerPath}");
                Logger.Log($"Contenuto answer.toml:\n{answerToml}");

                // Step 3: Formattazione USB e scrittura answer.toml
                lblStatus.Text = "Stato: Formattazione USB e scrittura risposta automatica...";
                progressBar.Value = 75;
                await FlashToUsbAsync(targetUsb.DeviceID, answerPath);

                progressBar.Value = 100;
                lblStatus.Text = "Stato: OPERAZIONE COMPLETATA CON SUCCESSO!";
                Logger.Log("=== OPERAZIONE COMPLETATA CON SUCCESSO ===");
                MessageBox.Show("Chiavetta USB configurata con successo!\n\nI dettagli sono stati salvati nel file app.log.", "Completato", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                Logger.Log($"ERRORE FATALE durante il processo: {ex}");
                MessageBox.Show($"Errore durante la creazione: {ex.Message}\n\nConsulta 'app.log' per maggiori dettagli.", "Errore Fatale", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
            sb.AppendLine($"source = \"{netSource}\"");
            sb.AppendLine($"cidr = \"{cidr}\"");
            sb.AppendLine($"gateway = \"{gateway}\"");
            sb.AppendLine("dns = \"1.1.1.1\"");
            sb.AppendLine("dns2 = \"8.8.8.8\"");
            sb.AppendLine();
            sb.AppendLine("[disk_setup]");
            sb.AppendLine("filesystem = \"zfs (RAID0)\"");
            sb.AppendLine("disk_list = [\"filter:first_matched\"]");

            return sb.ToString();
        }

        private async Task DownloadIsoAsync(string url, string destination)
        {
            if (File.Exists(destination))
            {
                long length = new FileInfo(destination).Length;
                if (length > 500 * 1024 * 1024)
                {
                    Logger.Log($"File ISO già presente e valido ({length} byte). Download saltato.");
                    return;
                }
                else
                {
                    Logger.Log($"File ISO incompleto o corrotto ({length} byte). Eliminazione in corso...");
                    File.Delete(destination);
                }
            }

            var handler = new HttpClientHandler { AllowAutoRedirect = true };
            using var client = new HttpClient(handler);
            client.Timeout = TimeSpan.FromMinutes(20);
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)");

            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            Logger.Log($"Risposta HTTP Download ISO: {response.StatusCode}");
            response.EnsureSuccessStatusCode();

            using var streamToRead = await response.Content.ReadAsStreamAsync();
            using var streamToWrite = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 8192, true);
            await streamToRead.CopyToAsync(streamToWrite);
            Logger.Log("Download ISO completato con successo.");
        }

        private async Task FlashToUsbAsync(string deviceId, string answerPath)
        {
            await Task.Run(() =>
            {
                string diskNum = Regex.Match(deviceId, @"\d+").Value;
                if (string.IsNullOrEmpty(diskNum))
                {
                    throw new Exception($"Impossibile estrarre il numero di disco da DeviceID: {deviceId}");
                }

                Logger.Log($"Numero disco identificato per diskpart: {diskNum}");

                string escapedAnswerPath = answerPath.Replace("\\", "\\\\");

                var sb = new StringBuilder();
                sb.AppendLine($"$diskNum = \"{diskNum}\"");
                sb.AppendLine($"$answer = \"{escapedAnswerPath}\"");
                
                // Script diskpart con etichetta PROXMOXAID (senza caratteri speciali per evitare errori FAT32)
                sb.AppendLine("$diskpartScript = @\"");
                sb.AppendLine("select disk $diskNum");
                sb.AppendLine("clean");
                sb.AppendLine("convert mbr");
                sb.AppendLine("create partition primary");
                sb.AppendLine("format fs=fat32 quick label=\"PROXMOXAID\"");
                sb.AppendLine("active");
                sb.AppendLine("assign");
                sb.AppendLine("\"@");

                sb.AppendLine("$dpOutput = $diskpartScript | diskpart");
                sb.AppendLine("Write-Host $dpOutput");

                // Controllo immediato di eventuali errori generati da diskpart
                sb.AppendLine("if ($dpOutput -match 'Errore del servizio Dischi virtuali' -or $dpOutput -match 'Error') {");
                sb.AppendLine("    throw 'Errore durante la formattazione con DiskPart.'");
                sb.AppendLine("}");

                sb.AppendLine("Start-Sleep -Seconds 4");

                // Estrazione e pulizia della lettera di unità
                sb.AppendLine("$vol = Get-Partition -DiskNumber $diskNum | Get-Volume");
                sb.AppendLine("if ($vol -and $vol.DriveLetter) {");
                sb.AppendLine("    $driveLetter = $vol.DriveLetter.ToString().Trim()");
                sb.AppendLine("    Write-Host \"Lettera unità assegnata: '$driveLetter'\"");
                sb.AppendLine("    if (Test-Path \"${driveLetter}:\") {");
                sb.AppendLine("        Copy-Item -Path $answer -Destination \"${driveLetter}:\\answer.toml\" -Force -ErrorAction Stop");
                sb.AppendLine("        Write-Host \"Copia answer.toml completata con successo.\"");
                sb.AppendLine("    } else {");
                sb.AppendLine("        throw \"Impossibile accedere all unità formattata (${driveLetter}:).\"");
                sb.AppendLine("    }");
                sb.AppendLine("} else {");
                sb.AppendLine("    throw \"Impossibile identificare la lettera di unità assegnata alla USB.\"");
                sb.AppendLine("}");

                var psi = new ProcessStartInfo("powershell")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                psi.ArgumentList.Add("-NoProfile");
                psi.ArgumentList.Add("-ExecutionPolicy");
                psi.ArgumentList.Add("Bypass");
                psi.ArgumentList.Add("-Command");
                psi.ArgumentList.Add(sb.ToString());

                Logger.Log("Esecuzione dello script PowerShell per Formattazione e Scrittura...");
                using var proc = Process.Start(psi);
                if (proc != null)
                {
                    string output = proc.StandardOutput.ReadToEnd();
                    string error = proc.StandardError.ReadToEnd();
                    proc.WaitForExit();

                    Logger.Log($"[PowerShell Output]:\n{output}");
                    if (!string.IsNullOrWhiteSpace(error))
                    {
                        Logger.Log($"[PowerShell Errore]:\n{error}");
                    }

                    if (proc.ExitCode != 0 || output.Contains("Errore del servizio Dischi virtuali") || output.Contains("throw"))
                    {
                        throw new Exception("La formattazione USB o la copia del file answer.toml è fallita. Verifica app.log.");
                    }
                }
                else
                {
                    throw new Exception("Impossibile avviare il processo PowerShell.");
                }
            });
        }
    }

    public class UsbDriveItem
    {
        public string DisplayName { get; set; } = "";
        public string DeviceID { get; set; } = "";
        public override string ToString() => DisplayName;
    }
}
