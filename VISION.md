# Masair

## Vision

Masair is a fast, low-poly motorcycle riding game inspired by the feel of Café Racer: first-person riding, satisfying motorcycle control, moving traffic, and an endless road that stays interesting through visual and route variety.

The player should be able to launch the game and immediately enjoy riding. The game is about speed, flow, near misses, corners, and the changing world ahead—not about story or complicated systems.

## Target

- Build and validate the first version on PC.
- Keep the technical and visual design mobile-ready from the beginning.
- Add Android support after the PC riding prototype feels good.

## Core experience

- First-person camera.
- No visible player character or rider model required.
- A starting motorcycle plus stronger distance-unlocked bikes, persistent
  currency, and engine, brake, and handling tuning.
- Endless forward ride through generated and authored road sections.
- Traffic to overtake, filter through, and avoid.
- Low-poly environments with strong silhouettes, color, lighting, and atmosphere.
- Fast restart and continuous riding.
- A small café-rider start menu with selectable light and traffic difficulty.

## Variety goal

The road must not feel like one repeating strip. The endless route should combine modular sections with different:

- Road shapes: straights, sweepers, hairpins, hills, dips, tunnels, bridges, and junctions.
- Environments: forest, coast, mountain, countryside, rain, and night.
- No city, and no buildings beside the road — no houses, villages, forecourts or
  roadworks. The route is meant to read as empty country roads, and a skyline of
  shopfronts is the one thing it should never ride into. The city scenery code
  is kept, unused, behind `RoadPath.THEME_POOL`.
- Traffic patterns and vehicle types.
- Landmarks, roadside details, weather, and fixed day/dusk/night moods.

The player should feel that the ride is continuously moving through a world, even though older sections are streamed out and new sections are created ahead.

## Explicit non-goals

- No story mode.
- No missions or quests.
- No open-world walking.
- No visible character customization.
- No multiplayer for the initial version.
- No complex motorcycle simulation that hurts playability.

## Art direction

- Original low-poly style inspired by the simplicity and atmosphere of Café Racer.
- Readable shapes and bold color palettes over high-detail materials.
- Motorcycle and important visual identity should become original Masair content.
- Premade models and assets may be used during private prototyping when they accelerate development.

## Performance direction

- Stream small road chunks instead of loading one huge world.
- Pool traffic and roadside objects.
- Use simple materials and shaders.
- Use texture atlases where practical.
- Use LODs and distance-based spawning.
- Keep active traffic and physics deliberately bounded.
- Profile on a real low-end target before adding visual effects.

## First playable milestone

The first playable build is complete when it has:

1. One controllable motorcycle.
2. A first-person camera.
3. One attractive endless road loop.
4. Basic traffic with collision and near-miss behavior.
5. At least three visibly different environment sections.
6. A restart button and distance/best-distance display.
7. Stable PC performance with a mobile-conscious rendering setup.

The first priority is riding feel. Content, customization, menus, and polish come after the motorcycle and road are enjoyable for several minutes.
