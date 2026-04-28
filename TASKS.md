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

Yeni iş açarken buraya kısa, doğrulanabilir kabul kriterleriyle ekle.
