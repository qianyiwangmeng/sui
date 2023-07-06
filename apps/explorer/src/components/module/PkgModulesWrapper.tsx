// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Combobox } from '@headlessui/react';
import { Search24 } from '@mysten/icons';
import clsx from 'clsx';
import { useState, useCallback, useEffect } from 'react';
import { type Direction } from 'react-resizable-panels';

import ModuleView from './ModuleView';
import { ModuleFunctionsInteraction } from './module-functions-interaction';
import { useBreakpoint } from '~/hooks/useBreakpoint';
import { SplitPanes } from '~/ui/SplitPanes';
import { TabHeader } from '~/ui/Tabs';
import { ListItem, VerticalList } from '~/ui/VerticalList';
import { useSearchParamsMerged } from '~/ui/utils/LinkWithQuery';

type ModuleType = [moduleName: string, code: string];

interface Props {
	id?: string;
	modules: ModuleType[];
	splitPanelOrientation: Direction;
}

interface ModuleViewWrapperProps {
	id?: string;
	selectedModuleName: string;
	modules: ModuleType[];
}

interface ModuleSourceViewWrapperProps {
	id?: string;
	selectedModuleName: string;
}

function ModuleViewWrapper({ id, selectedModuleName, modules }: ModuleViewWrapperProps) {
	const selectedModuleData = modules.find(([name]) => name === selectedModuleName);

	if (!selectedModuleData) {
		return null;
	}

	const [name, code] = selectedModuleData;

	return <ModuleView id={id} name={name} code={code} />;
}

interface Response {
	source: string;
}

function ModuleSourceViewWrapper({ id, selectedModuleName }: ModuleSourceViewWrapperProps) {
	const [source, setSource] = useState('');

	useEffect(() => {
		fetch(`http://localhost:8000/api?address=${id}&module=${selectedModuleName}`)
			.then((result) => {
				result.json().then((data: Response) => setSource(data.source));
			})
			.catch((err) => console.log(err));
	});

	return <ModuleView id={id} name={selectedModuleName} code={source} />;
}

function PkgModuleViewWrapper({ id, modules, splitPanelOrientation }: Props) {
	const isMediumOrAbove = useBreakpoint('md');

	const modulenames = modules.map(([name]) => name);
	const [searchParams, setSearchParams] = useSearchParamsMerged();
	const [query, setQuery] = useState('');

	// Extract module in URL or default to first module in list
	const selectedModule =
		searchParams.get('module') && modulenames.includes(searchParams.get('module')!)
			? searchParams.get('module')!
			: modulenames[0];

	console.log(`selectedModule: ${selectedModule}`);

	// If module in URL exists but is not in module list, then delete module from URL
	useEffect(() => {
		if (searchParams.has('module') && !modulenames.includes(searchParams.get('module')!)) {
			setSearchParams({}, { replace: true });
		}
	}, [searchParams, setSearchParams, modulenames]);

	const filteredModules =
		query === ''
			? modulenames
			: modules
					.filter(([name]) => name.toLowerCase().includes(query.toLowerCase()))
					.map(([name]) => name);

	const submitSearch = useCallback(() => {
		if (filteredModules.length === 1) {
			setSearchParams({
				module: filteredModules[0],
			});
		}
	}, [filteredModules, setSearchParams]);

	const onChangeModule = (newModule: string) => {
		setSearchParams({
			module: newModule,
		});
	};

	const bytecodeContent = [
		{
			panel: (
				<div key="source" className="h-full grow overflow-auto border-gray-45 pt-5 md:pl-7">
					<TabHeader size="md" title="Source">
						<div
							className={clsx(
								'overflow-auto',
								(splitPanelOrientation === 'horizontal' || !isMediumOrAbove) &&
									'h-verticalListLong',
							)}
						>
							<ModuleSourceViewWrapper id={id} selectedModuleName={selectedModule} />
						</div>
					</TabHeader>
				</div>
			),
			defaultSize: 50,
		},
		{
			panel: (
				<div key="bytecode" className="h-full grow overflow-auto border-gray-45 pt-5 md:pl-7">
					<TabHeader size="md" title="Bytecode">
						<div
							className={clsx(
								'overflow-auto',
								(splitPanelOrientation === 'horizontal' || !isMediumOrAbove) &&
									'h-verticalListLong',
							)}
						>
							<ModuleViewWrapper id={id} modules={modules} selectedModuleName={selectedModule} />
						</div>
					</TabHeader>
				</div>
			),
			defaultSize: 40,
		},
		{
			panel: (
				<div key="execute" className="h-full grow overflow-auto border-gray-45 pt-5 md:pl-7">
					<TabHeader size="md" title="Execute">
						<div
							className={clsx(
								'overflow-auto',
								(splitPanelOrientation === 'horizontal' || !isMediumOrAbove) &&
									'h-verticalListLong',
							)}
						>
							{id && selectedModule ? (
								<ModuleFunctionsInteraction
									// force recreating everything when we change modules
									key={`${id}-${selectedModule}`}
									packageId={id}
									moduleName={selectedModule}
								/>
							) : null}
						</div>
					</TabHeader>
				</div>
			),
			defaultSize: 10,
		},
	];

	return (
		<div className="flex flex-col gap-5 border-b border-gray-45 md:flex-row md:flex-nowrap">
			<div className="w-full md:w-1/5">
				<Combobox value={selectedModule} onChange={onChangeModule}>
					<div className="mt-2.5 flex w-full justify-between rounded-md border border-gray-50 py-1 pl-3 placeholder-gray-65 shadow-sm">
						<Combobox.Input
							onChange={(event) => setQuery(event.target.value)}
							displayValue={() => query}
							placeholder="Search"
							className="w-full border-none"
						/>
						<button onClick={submitSearch} className="border-none bg-inherit pr-2" type="submit">
							<Search24 className="h-4.5 w-4.5 cursor-pointer fill-steel align-middle text-gray-60" />
						</button>
					</div>
					<Combobox.Options className="absolute left-0 z-10 flex h-fit max-h-verticalListLong w-full flex-col gap-1 overflow-auto rounded-md bg-white px-2 pb-5 pt-3 shadow-moduleOption md:left-auto md:w-1/6">
						{filteredModules.length > 0 ? (
							<div className="ml-1.5 pb-2 text-caption font-semibold uppercase text-gray-75">
								{filteredModules.length}
								{filteredModules.length === 1 ? ' Result' : ' Results'}
							</div>
						) : (
							<div className="px-3.5 pt-2 text-center text-body italic text-gray-70">
								No results
							</div>
						)}
						{filteredModules.map((name) => (
							<Combobox.Option key={name} value={name} className="list-none md:min-w-fit">
								{({ active }) => (
									<button
										type="button"
										className={clsx(
											'mt-0.5 block w-full cursor-pointer rounded-md border px-1.5 py-2 text-left text-body',
											active
												? 'border-transparent bg-sui/10 text-gray-80'
												: 'border-transparent bg-white font-medium text-gray-80',
										)}
									>
										{name}
									</button>
								)}
							</Combobox.Option>
						))}
					</Combobox.Options>
				</Combobox>
				<div className="h-verticalListShort overflow-auto pt-3 md:h-verticalListLong">
					<VerticalList>
						{modulenames.map((name) => (
							<div key={name} className="mx-0.5 mt-0.5 md:min-w-fit">
								<ListItem active={selectedModule === name} onClick={() => onChangeModule(name)}>
									{name}
								</ListItem>
							</div>
						))}
					</VerticalList>
				</div>
			</div>
			{isMediumOrAbove ? (
				<div className="w-4/5">
					<SplitPanes direction={splitPanelOrientation} splitPanels={bytecodeContent} />
				</div>
			) : (
				bytecodeContent.map((panel, index) => <div key={index}>{panel.panel}</div>)
			)}
		</div>
	);
}
export default PkgModuleViewWrapper;
