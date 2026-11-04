#Requires -Version 5.1
# Draw the real form to an image without showing it or invoking run handlers.
param([switch]$Details)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$null=[Reflection.Assembly]::LoadFile((Join-Path $root 'tinnosdebloat-win11.exe'))
[Windows.Forms.Application]::EnableVisualStyles()
$form=[TinnosDebloat.Ui]::Create()
$bitmap=$null
try {
    # Invisible/off-screen showing lets WinForms perform its normal child layout.
    $form.ShowInTaskbar=$false; $form.Opacity=0
    $form.StartPosition=[Windows.Forms.FormStartPosition]::Manual
    $form.Location=New-Object Drawing.Point(-32000,-32000)
    $form.Show(); [Windows.Forms.Application]::DoEvents(); $form.PerformLayout()
    if ($Details) {
        # Illustrative events only: never start provisioning on the developer's PC.
        $form.ApplyEvent('{"Kind":"Success","Task":"Chrome (example)","Message":"Installed and verified"}')
        $form.ApplyEvent('{"Kind":"Progress","Task":"Google Drive (example)","Message":"Installer running. Elapsed: 00:30. Remaining time: unavailable."}')
        $form.Controls.Find('detailsButton',$true)[0].PerformClick()
    } else {$form.Controls.Find('cleanupToggle',$true)[0].Checked=$true}
    [Windows.Forms.Application]::DoEvents(); $form.PerformLayout()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $docs=Join-Path $root 'docs'; $null=New-Item -Path $docs -ItemType Directory -Force
    $file=if ($Details) {'interface-details.png'} else {'interface.png'}
    $bitmap.Save((Join-Path $docs $file),[Drawing.Imaging.ImageFormat]::Png)
    Write-Output 'Interface preview rendered without deployment.'
} finally {if ($null -ne $bitmap) {$bitmap.Dispose()}; $form.Dispose()}
