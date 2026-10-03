import { docs, changelog } from '@/.source/server';
import { loader } from 'fumadocs-core/source';

export const source = loader({ baseUrl: '/docs', source: docs.toFumadocsSource() });
export const releases = loader({ baseUrl: '/changelog', source: changelog.toFumadocsSource() });
