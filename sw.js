// Service worker: reçoit les notifications même quand l'appli est fermée.
// Et garantit la dernière version: la page et ses fichiers viennent toujours du réseau (le cache du
// navigateur gardait jusqu'à 10 min, plus dans l'appli installée), avec repli sur le cache hors ligne.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return; // Supabase, polices, CDN: intouchés
  e.respondWith(fetch(e.request, { cache: 'no-cache' }).catch(() => caches.match(e.request)));
});

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data.json(); } catch { d = { title: 'Habitudes', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Habitudes', {
    body: d.body || '',
    icon: 'icon-512.png',
    badge: 'icon-512.png',
    tag: d.tag,
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const open = wins.find(w => w.url.includes('/habitudes/'));
    return open ? open.focus() : self.clients.openWindow(e.notification.data.url);
  })());
});
