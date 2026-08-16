const fs = require('fs');
const path = require('path');

const rootDir = path.resolve(__dirname, '..');
const manifest = { folders: [], thumbsDir: '_thumbs' };
let totalImages = 0;

const items = fs.readdirSync(rootDir);

items.forEach(item => {
    const itemPath = path.join(rootDir, item);
    if (!fs.statSync(itemPath).isDirectory()) return;
    if (item.startsWith('.') || item === 'node_modules') return;

    const extPriority = { '.png': 0, '.svg': 1, '.jpg': 2, '.jpeg': 3, '.gif': 4, '.webp': 5, '.bmp': 6 };
    const files = fs.readdirSync(itemPath);
    const imageFiles = files.filter(file => {
        if (file.startsWith('DELETE_')) return false;
        const ext = path.extname(file).toLowerCase();
        return extPriority.hasOwnProperty(ext);
    }).sort((a, b) => {
        const baseA = path.parse(a).name;
        const baseB = path.parse(b).name;
        if (baseA < baseB) return -1;
        if (baseA > baseB) return 1;
        return (extPriority[path.extname(a).toLowerCase()] || 99) - (extPriority[path.extname(b).toLowerCase()] || 99);
    });

    if (imageFiles.length === 0) return;

    manifest.folders.push({
        name: item,
        path: item,
        count: imageFiles.length,
        files: imageFiles,
        sizes: imageFiles.map(f => fs.statSync(path.join(itemPath, f)).size)
    });

    console.log('  ' + item + ': ' + imageFiles.length + ' images');
    totalImages += imageFiles.length;
});

const json = JSON.stringify(manifest, null, 4);
fs.writeFileSync(path.join(rootDir, 'manifest.json'), json);
fs.writeFileSync(path.join(rootDir, 'manifest.js'), 'window.MANIFEST = ' + json + ';');

console.log('');
console.log('manifest.json + manifest.js generated!');
console.log('Total folders: ' + manifest.folders.length);
console.log('Total images:  ' + totalImages);
