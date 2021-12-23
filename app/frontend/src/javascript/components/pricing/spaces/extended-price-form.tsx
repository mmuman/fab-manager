import React, { BaseSyntheticEvent } from 'react';
import { Price } from '../../../models/price';
import { useTranslation } from 'react-i18next';
import { useImmer } from 'use-immer';
import { FabInput } from '../../base/fab-input';
import { IFablab } from '../../../models/fablab';

declare let Fablab: IFablab;

interface ExtendedPriceFormProps {
  formId: string,
  onSubmit: (pack: Price) => void,
  price?: Price,
}

/**
 * A form component to create/edit a extended price.
 * The form validation must be created elsewhere, using the attribute form={formId}.
 */
export const ExtendedPriceForm: React.FC<ExtendedPriceFormProps> = ({ formId, onSubmit, price }) => {
  const [extendedPriceData, updateExtendedPriceData] = useImmer<Price>(price || {} as Price);

  const { t } = useTranslation('admin');

  /**
   * Callback triggered when the user sends the form.
   */
  const handleSubmit = (event: BaseSyntheticEvent): void => {
    event.preventDefault();
    onSubmit(extendedPriceData);
  };

  /**
   * Callback triggered when the user inputs an amount for the current extended price.
   */
  const handleUpdateAmount = (amount: string) => {
    updateExtendedPriceData(draft => {
      draft.amount = parseFloat(amount);
    });
  };

  /**
   * Callback triggered when the user inputs a number of minutes for the current extended price.
   */
  const handleUpdateHours = (minutes: string) => {
    updateExtendedPriceData(draft => {
      draft.duration = parseInt(minutes, 10);
    });
  };

  return (
    <form id={formId} onSubmit={handleSubmit} className="group-form">
      <label htmlFor="duration">{t('app.admin.calendar.minutes')} *</label>
      <FabInput id="duration"
        type="number"
        defaultValue={extendedPriceData?.duration || ''}
        onChange={handleUpdateHours}
        step={1}
        min={1}
        icon={<i className="fas fa-clock" />}
        required />
      <label htmlFor="amount">{t('app.admin.extended_price_form.amount')} *</label>
      <FabInput id="amount"
        type="number"
        step={0.01}
        min={0}
        defaultValue={extendedPriceData?.amount || ''}
        onChange={handleUpdateAmount}
        icon={<i className="fas fa-money-bill" />}
        addOn={Fablab.intl_currency}
        required />
    </form>
  );
};
