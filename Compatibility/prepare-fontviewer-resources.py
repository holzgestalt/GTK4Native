"""Adapt copied Apple-only XIB objects; original project resources stay intact."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

resources = Path(sys.argv[1])
for source in (resources / 'Base.lproj').glob('*.xib'):
    tree = ET.parse(source)
    if source.name == 'MainWindow.xib':
        objects = tree.getroot().find('objects')
        by_id = {element.get('id'): element for element in tree.iter() if element.get('id')}
        split = by_id['562']
        children = ET.SubElement(split, 'subviews')
        extent = split.find('rect')
        width, height = float(extent.get('width')), float(extent.get('height'))
        for ident, x, pane_width in [('636', 0, 250), ('604', 251, width - 251)]:
            pane = by_id[ident]
            objects.remove(pane)
            pane.find('rect').attrib.update(x=str(x), y='0', width=str(pane_width), height=str(height))
            children.append(pane)
        # Replace the old fixed-width table/separator composition with a split.
        content = by_id['604']
        content.tag = 'splitView'
        content.set('vertical', 'YES')
        content.set('dividerStyle', 'thin')
        content.set('translatesAutoresizingMaskIntoConstraints', 'YES')
        content.remove(content.find('constraints'))
        content.find('subviews').remove(by_id['5TH-aI-4yr'])
        table = by_id['552']
        # The old composition fixed this list at 130 points. GtkPaned now owns
        # its width; the frame below is only the initial preferred allocation.
        table.remove(table.find('constraints'))
        table.find('rect').attrib.update(x='0', y='0', width='130', height=str(height))
        detail = by_id['648']
        detail.set('vertical', 'NO')
        detail.find('rect').attrib.update(x='131', y='0', width=str(width-382), height=str(height))
        detail_children = list(detail.find('subviews'))
        for pane, y, pane_height in [(detail_children[0], 0, height-100), (detail_children[1], height-99, 99)]:
            pane.find('rect').attrib.update(x='0', y=str(y), width=str(width-382), height=str(pane_height))
    for element in tree.iter():
        if element.tag == 'tableCellView' and not element.get('identifier'):
            element.set('identifier', element.get('id', 'Cell'))
        if element.get('customClass') == 'GSSourceListButtonBar':
            element.attrib.pop('customClass')
        if element.tag == 'wkWebView':
            element.tag = 'customView'
            element.set('customClass', 'WKWebView')
            for child in list(element):
                if child.tag not in ('rect', 'autoresizingMask', 'connections'):
                    element.remove(child)
        if element.tag == 'font' and element.get('usesAppearanceFont') == 'YES':
            element.attrib.pop('usesAppearanceFont')
            element.set('metaFont', 'system')
    for connections in tree.iter('connections'):
        for outlet in list(connections):
            if outlet.tag == 'outlet' and outlet.get('property') == 'navigationDelegate':
                connections.remove(outlet)
    tree.write(resources / source.name, encoding='utf-8', xml_declaration=True)
