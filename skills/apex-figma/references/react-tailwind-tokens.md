# React + Tailwind token & layout mapping

Load when the codegen target is React + Tailwind. For other targets see § Stack assumptions
in `../SKILL.md`.

## Token mapping pattern

Extract once from the Figma MCP, define in the project's `@theme`, reference the token name
(never the raw value) from components:

```tsx
// Figma token: color/brand/primary → oklch(55% 0.22 260)
// Define in globals.css @theme:
//   --color-brand: oklch(55% 0.22 260);

// In component — reference the token name, not the raw value:
<button className="bg-brand text-brand-foreground hover:bg-brand/90">
  {label}
</button>
```

```tsx
// From Figma token: color/brand/primary → mapped to Tailwind token
<div className="bg-brand-primary text-brand-on-primary" />
```

## Auto layout → Flexbox/Grid mapping

| Figma auto layout | Tailwind class |
|-------------------|----------------|
| Direction: Horizontal | `flex flex-row` |
| Direction: Vertical | `flex flex-col` |
| Gap: 16 | `gap-4` |
| Padding: 12 16 | `py-3 px-4` |
| Align: Center | `items-center` |
| Justify: Space between | `justify-between` |
