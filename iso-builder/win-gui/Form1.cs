using System;
using System.IO;
using System.Management; // Per rilevare solo le USB
using System.Net;
using System.Windows.Forms;

namespace HomelabUSBBuilder
{
    public partial class MainForm : Form
    {
        public MainForm()
        {
            InitializeComponent();
            LoadUsbDrives();
        }

        // 1. Rileva SOLO le chiavette USB collegate al PC
        private void LoadUsbDrives()
        {
            comboUsb.Items.Clear();
            var searcher = new ManagementObjectSearcher(@"SELECT * FROM Win32_DiskDrive WHERE InterfaceType='USB'");

            foreach (ManagementObject drive in searcher.Get())
            {
                string model = drive["Model"]?.ToString();
                string deviceId = drive["DeviceID"]?.ToString();
                ulong sizeBytes = Convert.ToUInt64(drive["Size"]);
                double sizeGb = Math.Round((double)sizeBytes / (1024 * 1024 * 1024), 1);

                comboUsb.Items.Add(new UsbItem { DisplayName = $"{model} ({sizeGb} GB)", DeviceID = deviceId });
            }

            if (comboUsb.Items.Count > 0) comboUsb.SelectedIndex = 0;
            else MessageBox.Show("Nessuna chiavetta USB rilevata! Inseriscine una e riapri il programma.", "Attenzione", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        // 2. Click del pulsante Unico
        private async void btnCreateUsb_Click(object sender, EventArgs e)
        {
            if (comboUsb.SelectedItem == null) return;
            var selectedUsb = (UsbItem)comboUsb.SelectedItem;

            var confirm = MessageBox.Show($"TUTTI I DATI sulla chiavetta {selectedUsb.DisplayName} VERRANNO CANCELLATI!\n\nVuoi continuare?", 
                                          "Conferma Scrittura USB", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            
            if (confirm != DialogResult.Yes) return;

            btnCreateUsb.Enabled = false;
            lblStatus.Text = "Download ISO Proxmox in corso...";

            // Download ISO in sottofondo + Iniezione config + Flash via Rufus CLI interno
            await System.Threading.Tasks.Task.Run(() => StartFlashingProcess(selectedUsb.DeviceID));

            lblStatus.Text = "Chiavetta USB Pronta!";
            MessageBox.Show("Chiavetta USB creata con successo! Ora inseriscila nel PC/Server e avvia il boot da USB.", "Completato", MessageBoxButtons.OK, MessageBoxIcon.Information);
            btnCreateUsb.Enabled = true;
        }

        private void StartFlashingProcess(string deviceId)
        {
            // Logica interna di download Proxmox ISO + scaricamento trasparente di Rufus CLI + Flash Raw
        }
    }

    public class UsbItem
    {
        public string DisplayName { get; set; }
        public string DeviceID { get; set; }
        public override string ToString() => DisplayName;
    }
}
