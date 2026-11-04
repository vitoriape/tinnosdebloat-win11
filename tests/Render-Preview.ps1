#Requires -Version 5.1
# Draw the real form to an image without showing it or invoking run handlers.
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
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $docs=Join-Path $root 'docs'; $null=New-Item -Path $docs -ItemType Directory -Force
    $bitmap.Save((Join-Path $docs 'interface.png'),[Drawing.Imaging.ImageFormat]::Png)
    Write-Output 'Interface preview rendered without deployment.'
} finally {if ($null -ne $bitmap) {$bitmap.Dispose()}; $form.Dispose()}
