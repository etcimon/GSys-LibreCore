/** @type {import('tailwindcss').Config} */
import daisyui from 'daisyui'

export default {
    content: ['./index.html', './src-ts/**/*.{js,ts,jsx,tsx}'],
    theme: {
        extend: {},
    },
    plugins: [daisyui],
}
