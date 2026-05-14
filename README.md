# LabDroid Gateway

Android-first Lab Edge Controller.

Mục tiêu:
- Android tablet làm Gateway chính trong phòng lab
- Scan LAN nội bộ
- Detect port 5555
- ADB connect hàng loạt
- Push / open video
- Install APK
- Open app / URL
- PC chỉ là helper hoặc dashboard phụ

## Cài trên Termux / iSH / Linux

```bash
curl -L https://raw.githubusercontent.com/USERNAME/labdroid-gateway/main/install.sh | bash -s -- https://raw.githubusercontent.com/USERNAME/labdroid-gateway/main
