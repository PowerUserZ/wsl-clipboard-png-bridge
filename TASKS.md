# Önerilen Görevler (Kod İncelemesi Sonucu)

Bu görevler, mevcut kod tabanındaki hızlı bir incelemeye dayanır.

## 1) Yazım hatası düzeltme görevi

- **Başlık:** README’de “defence” → “defense” yazım standardizasyonu
- **Bağlam:** README güvenlik notlarında İngiliz İngilizcesi (“defence”) kullanıyor. Projede diğer metinler ABD İngilizcesine daha yakın bir tonda.
- **Yapılacaklar:**
  - README içindeki ilgili ifadeyi “defense” olarak güncelle.
  - Aynı kökten gelen diğer kelimelerde de tutarlılık kontrolü yap.
- **Kabul kriteri:** README’de tek bir yazım standardı (US English) kullanılmış olmalı.

## 2) Hata düzeltme görevi

- **Başlık:** `CLIPBOARD_CONVERT_TIMEOUT` için pozitif sayı doğrulaması
- **Bağlam:** `wsl-clipboard-png-bridge` dosyasında timeout yalnızca rakamlardan oluşuyor mu diye kontrol ediliyor (`^[0-9]+$`). Bu, `0` değerini de kabul ediyor. `timeout 0` pratikte dönüşümü anında sonlandırıp özelliği fiilen bozabilir.
- **Yapılacaklar:**
  - Doğrulamayı `^[1-9][0-9]*$` gibi gerçekten pozitif tamsayıya zorlayacak şekilde güncelle.
  - Geçersiz durumda stderr’e açıklayıcı bir uyarı bas.
- **Kabul kriteri:** `CLIPBOARD_CONVERT_TIMEOUT=0` verildiğinde güvenli varsayılan değere (`5`) dönülmeli ve uyarı logu görülmeli.

## 3) Kod yorumu / dokümantasyon tutarsızlığı düzeltme görevi

- **Başlık:** README’de bağımlılık listesi ile komut örneklerinin hizalanması
- **Bağlam:** README’nin “Requirements” bölümünde `curl` geçmiyor; ancak kurulum komutları `curl` kullanıyor. `install.sh` da `curl` bağımlılığı arıyor.
- **Yapılacaklar:**
  - README “Requirements” bölümüne `curl` ekle **veya** kurulum bölümünde `curl` gerektirmeyen yerel kurulum alternatifi ver.
  - “If any apt packages are missing…” kısmındaki paket listesiyle bire bir uyumlu hale getir.
- **Kabul kriteri:** Dokümantasyondaki gereksinimler, script’in gerçek bağımlılık kontrolleriyle tutarlı olmalı.

## 4) Test iyileştirme görevi

- **Başlık:** Konfigürasyon doğrulamalarını kapsayan basit bir shell test seti ekleme
- **Bağlam:** Projede CI’da yalnızca ShellCheck var; çalışma zamanı davranışları (env var fallback, timeout doğrulaması, lock davranışı) otomatik doğrulanmıyor.
- **Yapılacaklar:**
  - `tests/` altında Bats (veya POSIX shell tabanlı) testler ekle.
  - En az şu senaryoları kapsa:
    1. Geçersiz `CLIPBOARD_WATCH_INTERVAL` fallback’i,
    2. `CLIPBOARD_CONVERT_TIMEOUT=0` / geçersiz değer fallback’i,
    3. İkinci instance’ın lock nedeniyle temiz çıkışı.
  - CI workflow’una test adımını ekle.
- **Kabul kriteri:** PR’da yeni testler CI’da çalışıyor ve başarısız/başarılı durumları güvenilir biçimde raporluyor.
