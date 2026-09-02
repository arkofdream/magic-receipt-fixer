export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      account_transactions: {
        Row: {
          amount: number
          counter_customer_id: string | null
          created_at: string
          customer_id: string
          deleted_at: string | null
          deleted_by: string | null
          description: string
          document_no: string
          due_date: string | null
          id: string
          source: string
          source_id: string | null
          txn_date: string
          txn_type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          amount?: number
          counter_customer_id?: string | null
          created_at?: string
          customer_id: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          due_date?: string | null
          id?: string
          source?: string
          source_id?: string | null
          txn_date?: string
          txn_type?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          amount?: number
          counter_customer_id?: string | null
          created_at?: string
          customer_id?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          due_date?: string | null
          id?: string
          source?: string
          source_id?: string | null
          txn_date?: string
          txn_type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_transactions_counter_customer_id_fkey"
            columns: ["counter_customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "account_transactions_counter_customer_id_fkey"
            columns: ["counter_customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "account_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      accounting_periods: {
        Row: {
          closed_at: string | null
          closed_by: string | null
          created_at: string
          id: string
          is_closed: boolean
          period_month: number
          period_year: number
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          is_closed?: boolean
          period_month: number
          period_year: number
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          is_closed?: boolean
          period_month?: number
          period_year?: number
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      admin_audit_log: {
        Row: {
          action: string
          admin_user_id: string
          created_at: string
          details: Json
          id: string
          target_user_id: string | null
        }
        Insert: {
          action: string
          admin_user_id: string
          created_at?: string
          details?: Json
          id?: string
          target_user_id?: string | null
        }
        Update: {
          action?: string
          admin_user_id?: string
          created_at?: string
          details?: Json
          id?: string
          target_user_id?: string | null
        }
        Relationships: []
      }
      audit_logs: {
        Row: {
          action: string
          created_at: string
          details: Json
          id: string
          record_id: string | null
          table_name: string
          user_id: string
        }
        Insert: {
          action: string
          created_at?: string
          details?: Json
          id?: string
          record_id?: string | null
          table_name: string
          user_id: string
        }
        Update: {
          action?: string
          created_at?: string
          details?: Json
          id?: string
          record_id?: string | null
          table_name?: string
          user_id?: string
        }
        Relationships: []
      }
      chart_of_accounts: {
        Row: {
          account_type: string
          code: string
          created_at: string
          id: string
          is_active: boolean
          is_system: boolean
          level: number
          name: string
          normal_balance: string
          parent_id: string | null
          system_tag: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          account_type: string
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          level?: number
          name: string
          normal_balance: string
          parent_id?: string | null
          system_tag?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          account_type?: string
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          level?: number
          name?: string
          normal_balance?: string
          parent_id?: string | null
          system_tag?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "chart_of_accounts_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "chart_of_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chart_of_accounts_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "v_account_balances"
            referencedColumns: ["account_id"]
          },
        ]
      }
      customers: {
        Row: {
          address: string
          city: string
          code: string
          contact_name: string
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          district: string
          email: string
          id: string
          neighborhood: string
          note: string
          opening_balance: number
          partner_group: string
          partner_type: string
          payment_term_days: number
          phone: string
          risk_limit: number
          tax_office: string
          title: string
          updated_at: string
          user_id: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          city?: string
          code?: string
          contact_name?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          note?: string
          opening_balance?: number
          partner_group?: string
          partner_type?: string
          payment_term_days?: number
          phone?: string
          risk_limit?: number
          tax_office?: string
          title: string
          updated_at?: string
          user_id: string
          vkn_tckn: string
        }
        Update: {
          address?: string
          city?: string
          code?: string
          contact_name?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          note?: string
          opening_balance?: number
          partner_group?: string
          partner_type?: string
          payment_term_days?: number
          phone?: string
          risk_limit?: number
          tax_office?: string
          title?: string
          updated_at?: string
          user_id?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
      efatura_connection_settings: {
        Row: {
          active_provider: string
          created_at: string
          gib_enabled: boolean
          gib_environment: string
          gib_last_error: string
          gib_last_tested_at: string | null
          gib_password_encrypted: string | null
          gib_status: string
          gib_username: string
          integrator_api_key_encrypted: string | null
          integrator_api_username: string
          integrator_base_url: string
          integrator_enabled: boolean
          integrator_last_error: string
          integrator_last_tested_at: string | null
          integrator_provider: string
          integrator_sender_alias: string | null
          integrator_status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_sender_alias?: string | null
          integrator_status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_sender_alias?: string | null
          integrator_status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      entry_counters: {
        Row: {
          counter_type: string
          last_number: number
          updated_at: string
          user_id: string
          year: number
        }
        Insert: {
          counter_type?: string
          last_number?: number
          updated_at?: string
          user_id: string
          year: number
        }
        Update: {
          counter_type?: string
          last_number?: number
          updated_at?: string
          user_id?: string
          year?: number
        }
        Relationships: []
      }
      invoice_items: {
        Row: {
          created_at: string
          currency: string
          description: string
          discount_amount: number
          discount_rate: number
          exchange_rate: number
          foreign_amount: number | null
          id: string
          invoice_id: string
          line_number: number
          line_total: number
          name: string
          product_id: string | null
          purchase_price: number | null
          quantity: number
          subtotal: number
          taxable_amount: number
          total_cost: number
          unit: string
          unit_cost: number
          unit_price: number
          user_id: string
          vat_amount: number
          vat_rate: number
        }
        Insert: {
          created_at?: string
          currency?: string
          description?: string
          discount_amount?: number
          discount_rate?: number
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          invoice_id: string
          line_number?: number
          line_total?: number
          name?: string
          product_id?: string | null
          purchase_price?: number | null
          quantity?: number
          subtotal?: number
          taxable_amount?: number
          total_cost?: number
          unit?: string
          unit_cost?: number
          unit_price?: number
          user_id: string
          vat_amount?: number
          vat_rate?: number
        }
        Update: {
          created_at?: string
          currency?: string
          description?: string
          discount_amount?: number
          discount_rate?: number
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          invoice_id?: string
          line_number?: number
          line_total?: number
          name?: string
          product_id?: string | null
          purchase_price?: number | null
          quantity?: number
          subtotal?: number
          taxable_amount?: number
          total_cost?: number
          unit?: string
          unit_cost?: number
          unit_price?: number
          user_id?: string
          vat_amount?: number
          vat_rate?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_items_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "product_stocks"
            referencedColumns: ["product_id"]
          },
          {
            foreignKeyName: "invoice_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_tax_lines: {
        Row: {
          created_at: string
          currency: string
          direction: string
          exchange_rate: number
          exemption_code: string | null
          id: string
          invoice_id: string
          is_audit_adjusted: boolean
          is_cancelled: boolean
          is_exempt: boolean
          is_reversal: boolean
          period_month: number
          period_year: number
          reversal_of: string | null
          tax_amount: number
          tax_amount_try: number
          tax_category: string
          taxable_amount: number
          taxable_amount_try: number
          user_id: string
          vat_rate: number
          withholding_amount: number
          withholding_rate: number
        }
        Insert: {
          created_at?: string
          currency?: string
          direction?: string
          exchange_rate?: number
          exemption_code?: string | null
          id?: string
          invoice_id: string
          is_audit_adjusted?: boolean
          is_cancelled?: boolean
          is_exempt?: boolean
          is_reversal?: boolean
          period_month?: number
          period_year?: number
          reversal_of?: string | null
          tax_amount?: number
          tax_amount_try?: number
          tax_category?: string
          taxable_amount?: number
          taxable_amount_try?: number
          user_id: string
          vat_rate?: number
          withholding_amount?: number
          withholding_rate?: number
        }
        Update: {
          created_at?: string
          currency?: string
          direction?: string
          exchange_rate?: number
          exemption_code?: string | null
          id?: string
          invoice_id?: string
          is_audit_adjusted?: boolean
          is_cancelled?: boolean
          is_exempt?: boolean
          is_reversal?: boolean
          period_month?: number
          period_year?: number
          reversal_of?: string | null
          tax_amount?: number
          tax_amount_try?: number
          tax_category?: string
          taxable_amount?: number
          taxable_amount_try?: number
          user_id?: string
          vat_rate?: number
          withholding_amount?: number
          withholding_rate?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_tax_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_tax_lines_reversal_of_fkey"
            columns: ["reversal_of"]
            isOneToOne: false
            referencedRelation: "invoice_tax_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices: {
        Row: {
          buyer_name: string
          buyer_tax_number: string
          cancel_date: string | null
          created_at: string
          currency: string
          customer: Json
          customer_id: string | null
          deleted_at: string | null
          deleted_by: string | null
          edm_return_code: string
          edm_return_message: string
          edm_status: string
          error_code: string | null
          error_message: string | null
          ettn: string
          exchange_rate: number
          gib_approval_date: string | null
          grand_total: number
          id: string
          invoice_date: string
          invoice_number: string
          items: Json
          notes: string
          original_invoice_id: string | null
          payment_info: string
          posted: boolean
          processed_at: string | null
          provider: string
          provider_reference: string | null
          raw_ubl_xml: string | null
          response_metadata: Json | null
          seller_name: string
          seller_tax_number: string
          sent_at: string | null
          status: string
          subtotal: number
          taxable_amount: number
          total_discount: number
          total_tevkifat: number
          total_vat: number
          trx_id: string | null
          type: string
          updated_at: string
          user_id: string
          warehouse_id: string | null
        }
        Insert: {
          buyer_name?: string
          buyer_tax_number?: string
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          edm_return_code?: string
          edm_return_message?: string
          edm_status?: string
          error_code?: string | null
          error_message?: string | null
          ettn: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number: string
          items?: Json
          notes?: string
          original_invoice_id?: string | null
          payment_info?: string
          posted?: boolean
          processed_at?: string | null
          provider?: string
          provider_reference?: string | null
          raw_ubl_xml?: string | null
          response_metadata?: Json | null
          seller_name?: string
          seller_tax_number?: string
          sent_at?: string | null
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          trx_id?: string | null
          type?: string
          updated_at?: string
          user_id: string
          warehouse_id?: string | null
        }
        Update: {
          buyer_name?: string
          buyer_tax_number?: string
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          edm_return_code?: string
          edm_return_message?: string
          edm_status?: string
          error_code?: string | null
          error_message?: string | null
          ettn?: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number?: string
          items?: Json
          notes?: string
          original_invoice_id?: string | null
          payment_info?: string
          posted?: boolean
          processed_at?: string | null
          provider?: string
          provider_reference?: string | null
          raw_ubl_xml?: string | null
          response_metadata?: Json | null
          seller_name?: string
          seller_tax_number?: string
          sent_at?: string | null
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          trx_id?: string | null
          type?: string
          updated_at?: string
          user_id?: string
          warehouse_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_original_invoice_id_fkey"
            columns: ["original_invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      journal_entries: {
        Row: {
          created_at: string
          description: string | null
          entry_date: string
          entry_number: string
          entry_type: string
          id: string
          period_month: number
          period_year: number
          source_id: string | null
          source_type: string | null
          status: string
          total_credit: number
          total_debit: number
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          entry_date?: string
          entry_number: string
          entry_type: string
          id?: string
          period_month: number
          period_year: number
          source_id?: string | null
          source_type?: string | null
          status?: string
          total_credit?: number
          total_debit?: number
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          entry_date?: string
          entry_number?: string
          entry_type?: string
          id?: string
          period_month?: number
          period_year?: number
          source_id?: string | null
          source_type?: string | null
          status?: string
          total_credit?: number
          total_debit?: number
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      journal_lines: {
        Row: {
          account_id: string
          created_at: string
          credit: number
          currency: string
          debit: number
          description: string | null
          exchange_rate: number
          foreign_amount: number | null
          id: string
          journal_entry_id: string
          user_id: string
        }
        Insert: {
          account_id: string
          created_at?: string
          credit?: number
          currency?: string
          debit?: number
          description?: string | null
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          journal_entry_id: string
          user_id: string
        }
        Update: {
          account_id?: string
          created_at?: string
          credit?: number
          currency?: string
          debit?: number
          description?: string | null
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          journal_entry_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "journal_lines_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "chart_of_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "journal_lines_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "v_account_balances"
            referencedColumns: ["account_id"]
          },
          {
            foreignKeyName: "journal_lines_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      legal_documents: {
        Row: {
          content: string
          created_at: string
          created_by: string | null
          doc_type: string
          id: string
          is_published: boolean
          published_at: string
          requires_reacceptance: boolean
          title: string
          updated_at: string
          version: string
        }
        Insert: {
          content: string
          created_at?: string
          created_by?: string | null
          doc_type: string
          id?: string
          is_published?: boolean
          published_at?: string
          requires_reacceptance?: boolean
          title: string
          updated_at?: string
          version: string
        }
        Update: {
          content?: string
          created_at?: string
          created_by?: string | null
          doc_type?: string
          id?: string
          is_published?: boolean
          published_at?: string
          requires_reacceptance?: boolean
          title?: string
          updated_at?: string
          version?: string
        }
        Relationships: []
      }
      pos_sales: {
        Row: {
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          description: string
          document_no: string
          gross_amount: number
          id: string
          net_amount: number
          payment_type: string
          sale_date: string
          updated_at: string
          user_id: string
          vat_amount: number
          vat_rate: number
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id: string
          vat_amount?: number
          vat_rate?: number
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id?: string
          vat_amount?: number
          vat_rate?: number
        }
        Relationships: []
      }
      products: {
        Row: {
          barcode: string
          category: string
          code: string
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          description: string
          discount_rate: number
          id: string
          min_stock: number
          name: string
          purchase_price: number
          track_stock: boolean
          unit: string
          unit_cost: number
          unit_price: number
          updated_at: string
          user_id: string
          vat_rate: number
        }
        Insert: {
          barcode?: string
          category?: string
          code?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          discount_rate?: number
          id?: string
          min_stock?: number
          name: string
          purchase_price?: number
          track_stock?: boolean
          unit?: string
          unit_cost?: number
          unit_price?: number
          updated_at?: string
          user_id: string
          vat_rate?: number
        }
        Update: {
          barcode?: string
          category?: string
          code?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          discount_rate?: number
          id?: string
          min_stock?: number
          name?: string
          purchase_price?: number
          track_stock?: boolean
          unit?: string
          unit_cost?: number
          unit_price?: number
          updated_at?: string
          user_id?: string
          vat_rate?: number
        }
        Relationships: []
      }
      profiles: {
        Row: {
          address: string
          company_title: string
          created_at: string
          email: string
          id: string
          phone: string
          tax_office: string
          updated_at: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Update: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id?: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
      stock_movements: {
        Row: {
          created_at: string
          customer_id: string | null
          deleted_at: string | null
          deleted_by: string | null
          description: string
          document_no: string
          id: string
          movement_date: string
          movement_type: string
          product_id: string
          quantity: number
          source: string
          source_id: string | null
          target_warehouse_id: string | null
          total_cost: number | null
          unit_cost: number | null
          unit_price: number
          updated_at: string
          user_id: string
          warehouse_id: string | null
        }
        Insert: {
          created_at?: string
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          id?: string
          movement_date?: string
          movement_type?: string
          product_id: string
          quantity?: number
          source?: string
          source_id?: string | null
          target_warehouse_id?: string | null
          total_cost?: number | null
          unit_cost?: number | null
          unit_price?: number
          updated_at?: string
          user_id: string
          warehouse_id?: string | null
        }
        Update: {
          created_at?: string
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          id?: string
          movement_date?: string
          movement_type?: string
          product_id?: string
          quantity?: number
          source?: string
          source_id?: string | null
          target_warehouse_id?: string | null
          total_cost?: number | null
          unit_cost?: number | null
          unit_price?: number
          updated_at?: string
          user_id?: string
          warehouse_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "stock_movements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "product_stocks"
            referencedColumns: ["product_id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_target_warehouse_id_fkey"
            columns: ["target_warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      subscription_reminders: {
        Row: {
          email: string
          end_date: string
          id: string
          sent_at: string
          threshold_days: number
          user_id: string
        }
        Insert: {
          email: string
          end_date: string
          id?: string
          sent_at?: string
          threshold_days: number
          user_id: string
        }
        Update: {
          email?: string
          end_date?: string
          id?: string
          sent_at?: string
          threshold_days?: number
          user_id?: string
        }
        Relationships: []
      }
      subscriptions: {
        Row: {
          created_at: string
          end_date: string
          id: string
          last_payment_date: string | null
          plan: string
          renewal_price: number | null
          start_date: string
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          end_date?: string
          id?: string
          last_payment_date?: string | null
          plan?: string
          renewal_price?: number | null
          start_date?: string
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          end_date?: string
          id?: string
          last_payment_date?: string | null
          plan?: string
          renewal_price?: number | null
          start_date?: string
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      user_consents: {
        Row: {
          accepted: boolean
          accepted_at: string
          consent_type: string
          created_at: string
          document_version: string
          id: string
          user_agent: string
          user_id: string
        }
        Insert: {
          accepted?: boolean
          accepted_at?: string
          consent_type: string
          created_at?: string
          document_version?: string
          id?: string
          user_agent?: string
          user_id: string
        }
        Update: {
          accepted?: boolean
          accepted_at?: string
          consent_type?: string
          created_at?: string
          document_version?: string
          id?: string
          user_agent?: string
          user_id?: string
        }
        Relationships: []
      }
      user_roles: {
        Row: {
          created_at: string
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
      warehouses: {
        Row: {
          address: string
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          id: string
          is_default: boolean
          name: string
          updated_at: string
          user_id: string
        }
        Insert: {
          address?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          is_default?: boolean
          name: string
          updated_at?: string
          user_id: string
        }
        Update: {
          address?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          is_default?: boolean
          name?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      customer_balances: {
        Row: {
          balance: number | null
          customer_id: string | null
          total_credit: number | null
          total_debit: number | null
          user_id: string | null
        }
        Relationships: []
      }
      product_stocks: {
        Row: {
          product_id: string | null
          quantity: number | null
          user_id: string | null
        }
        Relationships: []
      }
      v_account_balances: {
        Row: {
          account_code: string | null
          account_id: string | null
          account_name: string | null
          account_type: string | null
          credit_balance: number | null
          debit_balance: number | null
          is_system: boolean | null
          net_balance: number | null
          normal_balance: string | null
          total_credit: number | null
          total_debit: number | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      approve_purchase_invoice: {
        Args: { p_invoice_id: string }
        Returns: Json
      }
      approve_sales_invoice: { Args: { p_invoice_id: string }; Returns: Json }
      assert_accounting_period_open:
        | { Args: { p_date: string }; Returns: undefined }
        | { Args: { p_date: string; p_user_id: string }; Returns: undefined }
      assert_returnable_quantities: {
        Args: {
          p_items: Json
          p_original_invoice_id: string
          p_return_type: string
          p_user_id: string
        }
        Returns: undefined
      }
      cancel_purchase_invoice: {
        Args: { p_cancel_reason?: string; p_invoice_id: string }
        Returns: Json
      }
      cancel_sales_invoice: {
        Args: { p_cancel_reason?: string; p_invoice_id: string }
        Returns: Json
      }
      close_accounting_period: {
        Args: { p_month: number; p_year: number }
        Returns: Json
      }
      create_and_approve_purchase_invoice: {
        Args: {
          p_currency?: string
          p_ettn?: string
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_number: string
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_subtotal?: number
          p_supplier_id: string
          p_supplier_info?: Json
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_warehouse_id?: string
        }
        Returns: Json
      }
      create_and_approve_sales_invoice: {
        Args: {
          p_currency?: string
          p_customer_id?: string
          p_customer_info?: Json
          p_ettn?: string
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_number?: string
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_prefix?: string
          p_subtotal?: number
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_type?: string
          p_warehouse_id?: string
        }
        Returns: Json
      }
      create_purchase_invoice: {
        Args: {
          p_currency?: string
          p_ettn?: string
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_number: string
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_status?: string
          p_subtotal?: number
          p_supplier_id: string
          p_supplier_info?: Json
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_warehouse_id?: string
        }
        Returns: Json
      }
      create_purchase_return: {
        Args: {
          p_items: Json
          p_notes?: string
          p_original_invoice_id: string
          p_return_date: string
          p_return_invoice_number: string
          p_warehouse_id?: string
        }
        Returns: Json
      }
      create_sales_invoice: {
        Args: {
          p_currency?: string
          p_customer_id?: string
          p_customer_info?: Json
          p_ettn?: string
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_number?: string
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_prefix?: string
          p_status?: string
          p_subtotal?: number
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_type?: string
          p_warehouse_id?: string
        }
        Returns: Json
      }
      create_sales_return: {
        Args: {
          p_description?: string
          p_items: Json
          p_original_invoice_id: string
          p_return_date: string
          p_return_doc_no?: string
          p_warehouse_id?: string
        }
        Returns: Json
      }
      create_stock_valuation_adjustment: {
        Args: {
          p_adjustment_qty?: number
          p_description?: string
          p_document_no?: string
          p_new_unit_cost: number
          p_product_id: string
          p_valuation_date: string
          p_warehouse_id: string
        }
        Returns: Json
      }
      create_supplier_payment: {
        Args: {
          p_amount: number
          p_description?: string
          p_document_no?: string
          p_payment_date: string
          p_payment_method?: string
          p_supplier_id: string
        }
        Returns: Json
      }
      generate_invoice_tax_lines: {
        Args: { p_invoice_id: string }
        Returns: undefined
      }
      get_account_ledger: {
        Args: {
          p_account_id: string
          p_end_date?: string
          p_start_date?: string
        }
        Returns: {
          credit: number
          debit: number
          description: string
          entry_date: string
          entry_number: string
          journal_entry_id: string
          journal_line_id: string
          running_balance: number
          source_id: string
          source_type: string
        }[]
      }
      get_accounting_audit_summary: { Args: never; Returns: Json }
      get_customer_balances: {
        Args: never
        Returns: {
          balance: number
          customer_id: string
          total_credit: number
          total_debit: number
        }[]
      }
      get_foreign_currency_balances: { Args: never; Returns: Json }
      get_income_statement: {
        Args: { p_end_date?: string; p_start_date?: string }
        Returns: Json
      }
      get_product_stock_quantity: {
        Args: { p_product_id: string; p_warehouse_id?: string }
        Returns: number
      }
      get_reconciliation_summary: {
        Args: { p_month?: number; p_year?: number }
        Returns: Json
      }
      get_trial_balance: {
        Args: { p_end_date?: string; p_start_date?: string }
        Returns: {
          account_code: string
          account_id: string
          account_name: string
          account_type: string
          closing_credit: number
          closing_debit: number
          credit_balance: number
          debit_balance: number
          is_system: boolean
          net_balance: number
          normal_balance: string
          opening_credit: number
          opening_debit: number
          period_credit: number
          period_debit: number
        }[]
      }
      get_vat_declaration_summary: {
        Args: { p_month?: number; p_year?: number }
        Returns: Json
      }
      get_withholding_tax_summary: {
        Args: { p_month?: number; p_year?: number }
        Returns: Json
      }
      has_active_subscription: { Args: { _user_id: string }; Returns: boolean }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      next_entry_number: {
        Args: { p_type?: string; p_user_id: string; p_year: number }
        Returns: string
      }
      next_entry_number_with_prefix: {
        Args: { p_prefix?: string; p_user_id: string; p_year: number }
        Returns: string
      }
      process_customer_virman: {
        Args: {
          p_amount: number
          p_description?: string
          p_source_customer_id: string
          p_target_customer_id: string
          p_txn_date?: string
        }
        Returns: Json
      }
      process_invoice_payment: {
        Args: {
          p_amount: number
          p_description?: string
          p_document_no?: string
          p_invoice_id: string
          p_is_purchase?: boolean
          p_payment_date?: string
          p_payment_method?: string
        }
        Returns: Json
      }
      process_manual_account_transaction: {
        Args: {
          p_amount: number
          p_customer_id: string
          p_description?: string
          p_document_no?: string
          p_due_date?: string
          p_txn_date?: string
          p_txn_type: string
        }
        Returns: Json
      }
      process_manual_stock_movement: {
        Args: {
          p_description?: string
          p_document_no?: string
          p_movement_date?: string
          p_movement_type: string
          p_product_id: string
          p_quantity: number
          p_target_warehouse_id?: string
          p_unit_price?: number
          p_warehouse_id?: string
        }
        Returns: Json
      }
      reopen_accounting_period: {
        Args: { p_month: number; p_year: number }
        Returns: Json
      }
      run_accounting_audit: {
        Args: { p_month?: number; p_year?: number }
        Returns: {
          actual_value: number
          check_name: string
          detail: string
          difference: number
          expected_value: number
          severity: string
          source_id: string
          status: string
        }[]
      }
      run_fx_revaluation: {
        Args: {
          p_description?: string
          p_rates: Json
          p_revaluation_date: string
        }
        Returns: Json
      }
      update_and_approve_purchase_invoice: {
        Args: {
          p_currency?: string
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_id: string
          p_invoice_number: string
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_subtotal?: number
          p_supplier_id: string
          p_supplier_info?: Json
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_warehouse_id?: string
        }
        Returns: Json
      }
      update_purchase_invoice: {
        Args: {
          p_currency?: string
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_id: string
          p_invoice_number: string
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_status?: string
          p_subtotal?: number
          p_supplier_id: string
          p_supplier_info?: Json
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_warehouse_id?: string
        }
        Returns: Json
      }
    }
    Enums: {
      app_role: "admin" | "user"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["admin", "user"],
    },
  },
} as const
