const C = 'fchess-v9';
self.addEventListener('install', e => {
  e.waitUntil(caches.open(C).then(c => c.addAll(['./', 'index.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png'])).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== C).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const u = new URL(e.request.url);
  const ok = u.origin === location.origin || u.hostname === 'unpkg.com';
  if (!ok) return;
  e.respondWith(
    fetch(e.request).then(r => { if (r && r.ok && r.status === 200) { const cp = r.clone(); caches.open(C).then(c => c.put(e.request, cp)).catch(() => {}); } return r; })
      .catch(() => caches.match(e.request))
  );
});
