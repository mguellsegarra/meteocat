# Arquitectura i criteris de desenvolupament

Aquest document descriu els criteris vigents del projecte. Les declaracions d'API, els valors exactes i els formats persistits s'han de consultar al codi i als tests.

## Responsabilitats

`MeteocatCore` gestiona les metadades, els fotogrames, la descodificació PNG, la projecció, la cartografia, la caché i la configuració. `RadarService` i `SettingsStore` són actors. El client HTTP i el rellotge són injectables.

`MeteocatApp` gestiona les finestres AppKit i les vistes SwiftUI al main actor. `RadarViewModel` integra el servei i la configuració; `PlaybackController` controla la selecció, el rellotge de reproducció i les imatges presentades. Les vistes no han de duplicar el parser de tiles ni la gestió de xarxa o caché.

`FixtureImport` és una eina local d'importació, auditoria i verificació de recursos. L'empaquetament utilitza la seva verificació per detectar recursos absents després de traslladar l'app.

## Identitat i temps dels fotogrames

- Una observació s'identifica pel tipus i la data de validesa UTC. Una previsió inclou també la data UTC d'origen de la seva generació.
- La seqüència és cronològica. El servei considera fins a onze observacions i deu previsions d'un mateix origen, amb intervals de sis minuts.
- La línia temporal visible només afegeix previsions posteriors a l'última observació. Una previsió no s'ha de presentar com una observació.
- La data de comprovació del servei, la de validesa del fotograma i la d'origen de la previsió són conceptes diferents.
- Les fixtures utilitzen la seva data de captura com a referència i mai es presenten com a dades actuals.

## Xarxa, caché i cicle de vida

Obrir el servei carrega i valida l'estat local. L'activació del refresc és explícita i independent de la visibilitat de la finestra: ocultar el visor atura la feina de presentació, però permet continuar actualitzant la caché mentre el cicle de vida de l'app ho admeti.

`AppRefreshLifecycle` agrega els senyals públics de suspensió del sistema, sessió i pantalles. Les revisions de cicle de vida impedeixen que un lliurament asíncron antic substitueixi l'estat nou. La suspensió cancel·la el refresc i la presentació; la represa respecta la pausa explícita de l'usuari.

Només hi pot haver un cicle de refresc actiu. L'admissió persistent i el bloqueig entre processos limiten els intents, amb un interval de sis minuts més jitter de 20 a 40 segons. Els terminis de `Retry-After`, els límits de resposta i les cancel·lacions s'han de respectar.

La caché de disc està limitada a 192 MiB. Les escriptures són atòmiques; es validen hashes, PNG, identitats i manifests abans de promocionar dades. Un error conserva l'últim radar complet. Els fotogrames mostrats, en transició o en càrrega han de continuar protegits contra l'evicció.

`weather(for:)` només descodifica imatges locals. El mode fixture no fa peticions meteorològiques. Els tests han d'injectar clients HTTP i dades enregistrades.

## Mapa i imatges

La cartografia i el radar comparteixen el manifest de projecció EPSG:3857 i un espai canònic de 680 × 380, amb origen al nord-oest. Cal conservar els números de projecció, l'orientació TMS dels tiles i els bytes de les imatges originals.

Mapa, radar, ciutats i punt d'ubicació utilitzen una mateixa transformació afí uniforme. La càmera cobreix l'àrea disponible; les proporcions extremes de finestra poden retallar territori. Zoom i desplaçament són canvis de presentació, sense peticions addicionals de radar.

El raster canònic de verificació utilitza nearest-neighbour. El suavitzat espacial de la presentació nativa i la interpolació temporal poden barrejar píxels; no són noves mesures ni una preservació exacta dels píxels font.

La cartografia empaquetada i els seus manifests de procedència es versionen. `Scripts/Geography/derive-context-strokes.py` necessita els dos inputs conservats a `Design/border-fix-20261007/before/`; la resta de sortides de disseny són artefactes locals.

## Reproducció

La velocitat és ajustable a 0,5×, 1×, 2× i 4×. El pas nominal dura un segon a 1×. El radar, el rellotge visual i el slider comparteixen la mateixa transició ajustada a la velocitat.

Només s'interpolen passos consecutius cap endavant separats exactament per sis minuts. S'admet el pas d'observació a previsió; els canvis de generació de previsió, els salts temporals, les cerques, les pauses i els retorns al principi tallen la transició.

La barreja temporal opera sobre colors premultiplicats en espai lineal, en una sola superfície meteorològica. Els endpoints continuen sent els fotogrames originals. La interpolació de presentació no crea un fotograma nou al manifest.

Una càrrega fallida manté l'última imatge vàlida i la seva identitat. Una càrrega antiga no pot substituir una selecció posterior. Ocultar, suspendre, cercar o canviar la línia temporal invalida la feina pendent i reconcilia les proteccions de caché.

## Finestres i configuració

L'app mostra el visor a l'inici i admet els controls normals de finestra, redimensionament lliure, zoom i pantalla completa. La mida i la posició es persisteixen. Reobrir el visor no ha de crear una segona instància ni perdre la pausa o l'estat de reproducció.

La presència al Dock i a la barra de menús és configurable, però almenys una ha de quedar activa. Els canvis de focus i activació s'han de coordinar amb els menús i la finestra de configuració.

La configuració desa automàticament els canvis vàlids. Els esborranys incomplets i els errors de persistència han de continuar visibles sense descartar altres canvis. La gestió de ciutats conserva identificadors únics i valida noms, coordenades i el límit de seixanta entrades. Les actualitzacions del catàleg no han de recuperar ciutats que l'usuari ja havia eliminat.

La consulta d'ubicació és puntual i només comença amb una acció explícita. Cancel·lar-la o abandonar la secció invalida els resultats pendents. Les coordenades es desen localment i no s'envien al servei de radar.

Un fitxer de configuració malformat es copia abans de recuperar els valors inicials. El directori històric d'Application Support es conserva; la migració de geometria només consulta el domini antic si el nou encara no té cap valor desat.

## Validació

Els tests offline cobreixen contractes de dades, caché, configuració, càmera i reproducció. L'script d'empaquetament comprova els recursos traslladats, el plist i la signatura ad hoc.

Una compilació o un test no demostra el comportament de la interfície nativa. Els canvis de finestra o interacció requereixen comprovar l'app real: focus, menú, tancar i reobrir, redimensionament, teclat, zoom, slider, pausa, configuració i accessibilitat.

Els canvis de cicle de vida requereixen comprovacions natives de suspensió i represa, amb el visor visible i ocult. Els casos de sessió bloquejada, Spaces, pantalla completa i compatibilitat amb macOS 14 s'han de validar al seu entorn. La frescor de les dades només es pot confirmar amb una comprovació en viu explícita.

## Documentació

`README.md` explica l'ús i la compilació; aquest document conserva els criteris tècnics. Els contractes inicials, propostes, revisions, captures i registres de treball anteriors queden fora de Git. Les decisions futures s'han d'integrar en aquests documents, sense afegir transcripcions, repartiments d'agents ni registres de conversa.

## Idiomes

L'app inclou català, aranès, castellà, basc, gallec, anglès, francès, alemany, italià, portuguès, neerlandès, romanès, àrab estàndard, amazic estàndard del Marroc (tifinagh), urdú, xinès simplificat, ucraïnès, rus, polonès, panjabi (gurmukhi) i bengalí. A Configuració > General > Idioma pots seleccionar un dels 21 idiomes o seguir la preferència del sistema. El canvi es desa i s'aplica immediatament als textos i dates de l'app; el català és el recurs de reserva.

El radar conserva la disposició d'esquerra a dreta perquè les coordenades, els controls temporals i els obstacles del mapa tenen una geometria física comuna. Configuració segueix la direcció de la llengua, inclòs l'àrab i l'urdú. Les dates mantenen el calendari gregorià i Europe/Madrid; les hores mantenen HH:mm i els identificadors UTC no canvien.

`python3 Scripts/verify-localizations.py` valida les claus, els arguments i el text del permís d'ubicació. Amb `--app /ruta/Meteocat.app` també compara els recursos empaquetats. L'empaquetament executa aquesta comprovació. Les traduccions requereixen revisió lingüística nativa, especialment l'amazic.

La localització canvia a través d'un estat observable compartit. Les vistes llegeixen el mateix context; els menús i títols natius es tornen a titular sense substituir finestres ni controladors. Els missatges persistents es representen abans de traduir-los, i les dates es calculen amb la llengua activa. El canvi no reconcilia ni reinicia el radar, la reproducció o la sessió de Configuració. Les superfícies que gestiona macOS, com el permís d'ubicació, conserven la llengua del sistema.
