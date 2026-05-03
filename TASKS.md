# Görev Durumu

Bu dosya eski hızlı kod incelemesinden kalan önerileri takip etmek için
tutuluyor. Önceki maddeler tamamlandı:

- README yazım ve bağımlılık tutarlılığı güncellendi.
- `CLIPBOARD_CONVERT_TIMEOUT=0` ve diğer geçersiz sayısal değerler güvenli
  varsayılanlara düşüyor.
- Installer, mevcut managed `.bashrc` bloğunu güvenli biçimde yeniliyor ve
  bozuk veya birden fazla sentinel durumunda otomatik silme/yazma yapmıyor.
- `tests/run.sh` ile installer, env fallback, lock, active polling ve partial
  publish retry davranışları otomatik test ediliyor.

Güncel açık geliştirme fikirleri:

- Opsiyonel `systemd --user` install modu ekle. Kabul kriteri: systemd açık
  WSL ortamında service enable/start/status çalışmalı; systemd kapalıysa
  mevcut `.bashrc` akışı bozulmadan kalmalı.
- Bash dışı shell auto-start dokümantasyonunu genişlet veya zsh/fish için
  managed block desteği ekle. Kabul kriteri: zsh/fish kullanıcıları daemon'ın
  yeni shell/boot sonrası nasıl başlayacağını README'den açıkça görebilmeli.
- JPEG/WebP clipboard formatlarını ancak gerçek WSLg/ShareX örneğiyle
  doğrulandıktan sonra ekle. Kabul kriteri: format algılama ve conversion
  retry davranışı için fake clipboard regression bulunmalı.

Yeni iş açarken buraya kısa, doğrulanabilir kabul kriterleriyle ekle.
