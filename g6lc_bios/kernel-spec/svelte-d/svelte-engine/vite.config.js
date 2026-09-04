import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/postcss'
import autoprefixer from 'autoprefixer'
import fs from 'fs/promises'
import path from 'node:path'
import { WebSocketServer } from 'ws'
import { exec } from 'node:child_process'

const isProduction = process.env.NODE_ENV === 'production'
const port = process.env.PORT || 5173
const base = process.env.BASE || '/'

export default defineConfig({
    base,
    server: {
        port,
        // Remove middlewareMode to enable Vite's built-in HTTP server
        watch: {
            // Watch for changes in the WASM file
            ignored: ['!public/*.wasm', 'public/*-raw.wasm'],
        },
        hmr: false,
        headers: {
            'Cache-Control': 'no-store',
        },
    },
    build: {
        rollupOptions: {
            input: './index.html',
        },
    },
    css: {
        postcss: {
            plugins: [tailwindcss(), autoprefixer()],
        },
    },
    plugins: [
        {
            name: 'svelte-d-pages',
            configureServer(server) {
                server.middlewares.use((req, res, next) => {
                    const u = (req.url || '').split('?')[0]
                    const pages = ['overlay', 'ir']
                    const hit = pages.find(
                        (p) => u === '/__svelte-d/' + p || u === '/__svelte-d/' + p + '/'
                    )
                    if (!hit) return next()
                    const file = path.resolve(
                        server.config.root,
                        'public',
                        '__svelte-d',
                        hit,
                        'index.html'
                    )
                    fs.readFile(file, 'utf8')
                        .then((html) => {
                            res.statusCode = 200
                            res.setHeader('Content-Type', 'text/html; charset=utf-8')
                            res.end(html)
                        })
                        .catch(() => next())
                })
            },
        },
        {
            name: 'watch-wasm',
            configureServer(server) {
                const wss = new WebSocketServer({ port: 3001 })
                let building = false

                function notifyClients() {
                    const notifyFct = () => {
                        if (building) setTimeout(notifyFct, 200)
                        else
                            wss.clients.forEach((client) => {
                                console.log('..Posting hot reload... ')
                                if (client.readyState === 1) {
                                    // WebSocket.OPEN === 1
                                    client.send('reload')
                                }
                            })
                    }
                    notifyFct()
                }
                function reloadClients() {
                    wss.clients.forEach((client) => {
                        if (client.readyState === 1) {
                            // WebSocket.OPEN === 1
                            client.send('full-reload')
                        }
                    })
                }

                let lastModified = 0
                server.watcher.add('public/*.wasm')
                server.watcher.add('public/__svelte-d/hmr-tick')
                server.watcher.add('src-d/*.d')
                server.watcher.add('src-d-views/*')
                server.watcher.on('change', async (file) => {
                    if (file.endsWith('-raw.wasm')) return
                    if (file.replace(/\\/g, '/').includes('__svelte-d/hmr-tick')) {
                        const txt = await fs.readFile(file, 'utf8').catch(() => 'reload')
                        if (txt.includes('full-reload')) reloadClients()
                        else notifyClients()
                        return
                    }

                    if (file.endsWith('.wasm')) {
                        const stat = await fs.stat(file)
                        if (stat.size === 0) return
                        if (stat.mtimeMs !== lastModified) {
                            lastModified = stat.mtimeMs
                            notifyClients()
                        }
                    } else if (
                        file.endsWith('.d') ||
                        file.includes('src-d-views')
                    ) {
                        if (building) {
                            process.stdout.write('busy')
                            return
                        }
                        console.log('File changed: ', file)
                        process.stdout.write('Building...')
                        building = true
                        let startTime = performance.now()
                        try {
                            function showDot() {
                                setTimeout(() => {
                                    if (building) {
                                        process.stdout.write('.')
                                        showDot()
                                    }
                                }, 1000)
                            }

                            showDot()
                            await exec(
                                'dub build --arch=wasm32-unknown-wasi --compiler=ldc2 --config=application',
                                (error, stdout, stderr) => {
                                    if (error) {
                                        console.error(`exec error: ${error}`)
                                        building = false
                                        return
                                    }
                                    //if (stdout) console.log(`stdout: ${stdout}`)
                                    if (stderr)
                                        console.error(`stderr: ${stderr}`)

                                    console.log(
                                        'Built in ',
                                        (performance.now() - startTime) / 1000,
                                        's'
                                    )
                                    building = false
                                }
                            )
                        } catch (e) {
                            console.error(e)
                            building = false
                        }
                    } else if (file.includes('src-ts')) {
                        console.log('File changed: ', file)
                        reloadClients()
                    } else {
                        console.log('Uncaptured file change: ', file)
                    }
                })
            },
        },
    ],
})
